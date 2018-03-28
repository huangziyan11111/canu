
###############################################################################
 #
 #  This file is part of canu, a software program that assembles whole-genome
 #  sequencing reads into contigs.
 #
 #  This software is based on:
 #    'Celera Assembler' (http://wgs-assembler.sourceforge.net)
 #    the 'kmer package' (http://kmer.sourceforge.net)
 #  both originally distributed by Applera Corporation under the GNU General
 #  Public License, version 2.
 #
 #  Canu branched from Celera Assembler at its revision 4587.
 #  Canu branched from the kmer project at its revision 1994.
 #
 #  This file is derived from:
 #
 #    src/pipelines/ca3g/OverlapErrorAdjustment.pm
 #
 #  Modifications by:
 #
 #    Brian P. Walenz from 2015-FEB-27 to 2015-SEP-21
 #      are Copyright 2015 Battelle National Biodefense Institute, and
 #      are subject to the BSD 3-Clause License
 #
 #    Brian P. Walenz beginning on 2015-NOV-03
 #      are a 'United States Government Work', and
 #      are released in the public domain
 #
 #    Sergey Koren beginning on 2016-MAR-27
 #      are a 'United States Government Work', and
 #      are released in the public domain
 #
 #  File 'README.licenses' in the root directory of this distribution contains
 #  full conditions and disclaimers for each license.
 ##

package canu::OverlapErrorAdjustment;

require Exporter;

@ISA    = qw(Exporter);
@EXPORT = qw(readErrorDetectionConfigure readErrorDetectionCheck overlapErrorAdjustmentConfigure overlapErrorAdjustmentCheck updateOverlapStore);

use strict;

use File::Path 2.08 qw(make_path remove_tree);

use canu::Defaults;
use canu::Execution;
use canu::Gatekeeper;
use canu::Report;
use canu::Grid_Cloud;

#  Hardcoded to use utgOvlErrorRate


sub loadReadLengthsAndNumberOfOverlaps ($$$$) {
    my $asm     = shift @_;
    my $maxID   = shift @_;
    my $rlVec   = shift @_;
    my $rlSum   = 0;
    my $noVec   = shift @_;
    my $noSum   = 0;

    my $bin     = getBinDirectory();

    $$rlVec     = "\xff" x ($maxID * 4 + 4);
    $$noVec     = "\xff" x ($maxID * 4 + 4);

    print STDERR "--\n";
    print STDERR "-- Loading read lengths.\n";

    open(F, "$bin/gatekeeperDumpMetaData -G unitigging/$asm.gkpStore -reads |");
    while (<F>) {
        s/^\s+//;
        s/\s+$//;
        my @v = split '\s+', $_;
        vec($$rlVec, $v[0], 32) = $v[2];
        $rlSum                 += $v[2];
    }
    close(F);

    caExit("Failed to load read lengths from '$asm.gkpStore'", undef)   if ($rlSum == 0);


    fetchStore("unitigging/$asm.ovlStore");

    print STDERR "-- Loading number of overlaps per read.\n";

    open(F, "$bin/ovStoreDump -G unitigging/$asm.gkpStore -O unitigging/$asm.ovlStore -counts |");
    while (<F>) {
        s/^\s+//;
        s/\s+$//;
        my @v = split '\s+', $_;
        vec($$noVec, $v[0], 32) = $v[1];
        $noSum                 += $v[1];
    }
    close(F);

    caExit("Failed to load number of overlaps per read from '$asm.ovlStore'", undef)   if ($noSum == 0);

    return($rlSum, $noSum);
}



sub readErrorDetectionConfigure ($) {
    my $asm     = shift @_;
    my $bin     = getBinDirectory();
    my $path    = "unitigging/3-overlapErrorAdjustment";

    return         if (getGlobal("enableOEA") == 0);

    goto allDone   if (fileExists("$path/red.sh"));    #  Script exists
    goto allDone   if (fileExists("$path/red.red"));   #  Result exists

    goto allDone   if (skipStage($asm, "readErrorDetectionConfigure") == 1);

    goto allDone   if (fileExists("unitigging/$asm.ovlStore/evalues"));   #  Stage entrely finished
    goto allDone   if (-d "unitigging/$asm.ctgStore");                    #  Assembly finished

    make_path("$path")  if (! -d "$path");

    my $maxID = getNumberOfReadsEarliestVersion($asm);

    my ($rlVec, $noVec);
    my ($rlSum, $noSum) = loadReadLengthsAndNumberOfOverlaps($asm, $maxID, \$rlVec, \$noVec);

    #  Find the maximum size of each block of 100,000 reads.  findErrors reads up to 100,000 reads
    #  to process at one time.  It uses 1 * length + 4 * 100,000 bytes of memory for bases and ID storage,
    #  and has two buffers of this size.

    my $maxBlockSize = 0;

    for (my $id = 1; $id <= $maxID; $id += 100000) {
        my $sum = 0;

        for (my $ii=$id; ($ii < $id + 100000) && ($ii < $maxID); $ii++) {
            $sum += vec($rlVec, $ii, 32);
        }

        $maxBlockSize = $sum   if ($maxBlockSize < $sum);
    }

    my $maxMem   = getGlobal("redMemory") * 1024 * 1024 * 1024;
    my $maxReads = getGlobal("redBatchSize");
    my $maxBases = getGlobal("redBatchLength");

    print STDERR "--\n";
    print STDERR "-- Configure RED for ", getGlobal("redMemory"), "gb memory.\n";
    print STDERR "--                   Batches of at most ", ($maxReads > 0) ? $maxReads : "(unlimited)", " reads.\n";
    print STDERR "--                                      ", ($maxBases > 0) ? $maxBases : "(unlimited)", " bases.\n";
    print STDERR "--                   Expecting evidence of at most $maxBlockSize bases per iteration.\n";
    print STDERR "--\n";
    print STDERR "--           Total                                               Reads                 Olaps Evidence\n";
    print STDERR "--    Job   Memory      Read Range         Reads        Bases   Memory        Olaps   Memory   Memory  (Memory in MB)\n";
    print STDERR "--   ---- -------- ------------------- --------- ------------ -------- ------------ -------- --------\n";

    my $reads    = 0;
    my $bases    = 0;
    my $olaps    = 0;

    my @bgn;
    my @end;
    my $nj = 0;

    push @bgn, 1;

    for (my $id = 1; $id <= $maxID; $id++) {
        if (vec($rlVec, $id, 32) > 0) {
            $reads += 1;
            $bases += vec($rlVec, $id, 32);
            $olaps += vec($noVec, $id, 32);
        }

        #  Memory usage:
        #
        #  Per base/vote:
        #    1 byte  for sequence
        #   12 bytes for Vote_Tally_t
        #
        #  Per read:
        #   32 bytes for Frag_Info_t
        #
        #  Per olap:
        #   12 bytes for Olap_Info_t
        #
        #  When processing, the overlapping reads are loaded in batches of up to 100,000 reads
        #  (depending on overlaps).  This needs 1 byte per base, but we don't know how many reads
        #  are getting loaded, so we overestimate by finding the largest block of 100,000 reads that
        #  could be loaded (done above) and using 2x that (because there are two buffers of these
        #  reads).
        #
        #  Throw in another 2 GB for unknown overheads (gkpStore, ovlStore) and alignment generation.

        my $memory = (12 * $bases) + (33 * $reads) + (12 * $olaps) + (2 * $maxBlockSize) + 2 * 1024 * 1024 * 1024;

        if ((($maxMem   > 0) && ($memory >= $maxMem))    ||
            (($maxReads > 0) && ($reads  >= $maxReads))  ||
            (($maxBases > 0) && ($bases  >= $maxBases))  ||
            (($id == $maxID))) {
            push @end, $id;

            printf(STDERR "--   %4u %8.2f %9u-%-9u %9u %12u %8.2f %12u %8.2f %8.2f\n",
                   $nj + 1,
                   $memory / 1024 / 1024,
                   $bgn[$nj], $end[$nj],
                   $reads,
                   $bases,               (12 * $bases + 33 * $reads)  / 1024 / 1024,
                   $olaps,               (12 * $olaps)                / 1024 / 1024,
                   2 * $maxBlockSize / 1024 / 1024);

            $nj++;

            $reads = 0;
            $bases = 0;
            $olaps = 0;

            push @bgn, $id + 1;  #  RED expects inclusive ranges.
        }
    }

    print  STDERR "--   ---- -------- ------------------- --------- ------------ -------- ------------ -------- --------\n";
    printf(STDERR "--                                               %12u          %12u\n",
           $rlSum, $noSum);

    #  Dump a script.

    my $batchSize   = getGlobal("redBatchSize");
    my $numThreads  = getGlobal("redThreads");

    open(F, "> $path/red.sh") or caExit("can't open '$path/red.sh' for writing: $!", undef);

    print F "#!" . getGlobal("shell") . "\n\n";
    print F "\n";
    print F getBinDirectoryShellCode();
    print F "\n";
    print F setWorkDirectoryShellCode($path);
    print F fetchStoreShellCode("unitigging/$asm.gkpStore", $path, "");
    print F fetchStoreShellCode("unitigging/$asm.ovlStore", $path, "");
    print F "\n";
    print F getJobIDShellCode();
    print F "\n";

    for (my $jj=1; $jj <= $nj; $jj++) {
        print F "if [ \$jobid = $jj ] ; then\n";
        print F "  minid=$bgn[$jj-1]\n";
        print F "  maxid=$end[$jj-1]\n";
        print F "fi\n";
    }

    print F "jobid=`printf %05d \$jobid`\n";
    print F "\n";
    print F "if [ -e ./\$jobid.red ] ; then\n";
    print F "  echo Job previously completed successfully.\n";
    print F "  exit\n";
    print F "fi\n";
    print F "\n";
    print F "\$bin/findErrors \\\n";
    print F "  -G ../$asm.gkpStore \\\n";
    print F "  -O ../$asm.ovlStore \\\n";
    print F "  -R \$minid \$maxid \\\n";
    print F "  -e " . getGlobal("utgOvlErrorRate") . " -l " . getGlobal("minOverlapLength") . " \\\n";
    print F "  -o ./\$jobid.red.WORKING \\\n";
    print F "  -t $numThreads \\\n";
    print F "&& \\\n";
    print F "mv ./\$jobid.red.WORKING ./\$jobid.red\n";
    print F "\n";
    print F stashFileShellCode("$path", "\$jobid.red", "");
    print F "\n";

    close(F);

    makeExecutable("$path/red.sh");
    stashFile("$path/red.sh");

  finishStage:
    emitStage($asm, "readErrorDetectionConfigure");

  allDone:
}





sub readErrorDetectionCheck ($) {
    my $asm     = shift @_;
    my $attempt = getGlobal("canuIteration");
    my $path    = "unitigging/3-overlapErrorAdjustment";

    return         if (getGlobal("enableOEA") == 0);

    goto allDone   if (fileExists("$path/red.red"));       #  Output exists

    goto allDone   if (skipStage($asm, "readErrorDetectionCheck", $attempt) == 1);

    goto allDone   if (fileExists("unitigging/$asm.ovlStore/evalues"));   #  Stage entrely finished
    goto allDone   if (-d "unitigging/$asm.ctgStore");                    #  Assembly finished

    fetchFile("$path/red.sh");

    #  Figure out if all the tasks finished correctly.

    my @successJobs;
    my @failedJobs;
    my $failureMessage = "";

    open(A, "< $path/red.sh") or caExit("can't open '$path/red.sh' for reading: $!", undef);
    while (<A>) {
        if (m/if.*jobid\s+=\s+(\d+)\s+.*then/) {
            my $ji = substr("00000" . $1, -5);
            my $jn = "unitigging/3-overlapErrorAdjustment/$ji.red";

            if (! fileExists($jn)) {
                $failureMessage .= "--   job $ji.red FAILED.\n";
                push @failedJobs, $1;
            } else {
                push @successJobs, $jn;
            }
        }
    }
    close(A);

    #  Failed jobs, retry.

    if (scalar(@failedJobs) > 0) {

        #  If too many attempts, give up.

        if ($attempt >= getGlobal("canuIterationMax")) {
            print STDERR "--\n";
            print STDERR "-- Read error detection jobs failed, tried $attempt times, giving up.\n";
            print STDERR $failureMessage;
            print STDERR "--\n";
            caExit(undef, undef);
        }

        if ($attempt > 0) {
            print STDERR "--\n";
            print STDERR "-- Read error detection jobs failed, retry.\n";
            print STDERR $failureMessage;
            print STDERR "--\n";
        }

        #  Otherwise, run some jobs.

        emitStage($asm, "readErrorDetectionCheck", $attempt);

        submitOrRunParallelJob($asm, "red", $path, "red", @failedJobs);
        return;
    }


  finishStage:
    print STDERR "-- Found ", scalar(@successJobs), " read error detection output files.\n";

    #  I didn't wan't to concat all the corrections, but it is _vastly_ easier to do so, compared to
    #  hacking correctOverlaps to handle multiple corrections files.  Plus, it is now really just a
    #  concat; before, the files needed to be parsed to strip off a header.

    open(O, "> $path/red.red") or caExit("can't open '$path/red.red' for writing: $!", undef);
    binmode(O);

    foreach my $f (@successJobs) {
        fetchFile($f);

        open(F, "< $f") or caExit("can't open '$f' for reading: $!", undef);
        binmode(F);

        my $buf;
        my $len = sysread(F, $buf, 1024 * 1024);

        while ($len > 0) {
            syswrite(O, $buf, $len);

            $len = sysread(F, $buf, 1024 * 1024);
        }

        close(F);
    }

    close(O);

    stashFile("$path/red.red");

    foreach my $f (@successJobs) {
        unlink $f;
    }

    emitStage($asm, "readErrorDetectionCheck");

  allDone:
}





sub overlapErrorAdjustmentConfigure ($) {
    my $asm     = shift @_;
    my $bin     = getBinDirectory();
    my $path    = "unitigging/3-overlapErrorAdjustment";

    return         if (getGlobal("enableOEA") == 0);

    goto allDone   if (fileExists("$path/oea.sh"));   #  Script exists

    goto allDone   if (skipStage($asm, "overlapErrorAdjustmentConfigure") == 1);

    goto allDone   if (fileExists("unitigging/$asm.ovlStore/evalues"));   #  Stage entrely finished
    goto allDone   if (-d "unitigging/$asm.ctgStore");                    #  Assembly finished

    my $maxID = getNumberOfReadsEarliestVersion($asm);

    my ($rlVec, $noVec);
    my ($rlSum, $noSum) = loadReadLengthsAndNumberOfOverlaps($asm, $maxID, \$rlVec, \$noVec);

    #  Make an array of partitions, putting as many reads into each as will fit in the desired memory.

  tryOEAagain:
    my @bgn;   undef @bgn;
    my @end;   undef @end;
    my @log;   undef @log;

    my $nj = 0;

    # get earliest count of reads in store
    my $maxID    = getNumberOfReadsEarliestVersion($asm);

    my $maxMem   = getGlobal("oeaMemory") * 1024 * 1024 * 1024;
    my $maxReads = getGlobal("oeaBatchSize");
    my $maxBases = getGlobal("oeaBatchLength");

    print STDERR "--\n";
    print STDERR "-- Configure OEA for ", getGlobal("oeaMemory"), "gb memory.\n";
    print STDERR "--                   Batches of at most ", ($maxReads > 0) ? $maxReads : "(unlimited)", " reads.\n";
    print STDERR "--                                      ", ($maxBases > 0) ? $maxBases : "(unlimited)", " bases.\n";
    print STDERR "--\n";

    my $reads    = 0;
    my $bases    = 0;
    my $olaps    = 0;

    fetchFile("$path/red.red");

    my $corrSize     = (-s "$path/red.red");

    my $smallJobs    = 0;
    my $smallJobSize = 1024;

    push @bgn, 1;

    for (my $id = 1; $id <= $maxID; $id++) {
        if (vec($rlVec, $id, 32) > 0) {
            $reads += 1;
            $bases += vec($rlVec, $id, 32);
            $olaps += vec($noVec, $id, 32);
        }

        #  OEA uses 1 byte/base + 8 bytes/adjustment + 28 bytes/overlap.  We don't know the number
        #  of adjustments, but that's basically error rate.  No adjustment is output for mismatches.

        #  Hacked to attempt to estimate adjustment size better.  Olaps should only require 12 bytes each.

        my $memBases  = (1    * $bases);              #  Corrected reads for this batch
        my $memAdj1   = (8    * $corrSize) * 0.33;    #  Overestimate of the size of the indel adjustments needed (total size includes mismatches)
        my $memReads  = (32   * $reads);              #  Read data in the batch
        my $memOlaps  = (32   * $olaps);              #  Loaded overlaps
        my $memSeq    = (4    * 2097152);             #  two char arrays of 2*maxReadLen
        my $memAdj2   = (16   * 2097152);             #  two Adjust_t arrays of maxReadLen
        my $memWA     = (32   * 1048576);             #  Work area (16mb) and edit array (16mb)
        my $memMisc   = (256  * 1048576);             #  Work area (16mb) and edit array (16mb) and (192mb) slop
        my $memExtra  = (2048 * 1048576);             #  For alignments and overhead.

        my $memory = $memBases + $memAdj1 + $memReads + $memOlaps + $memSeq + $memAdj2 + $memWA + $memMisc + $memExtra;

        if ((($maxMem   > 0) && ($memory >= $maxMem))   ||
            (($maxReads > 0) && ($reads  >= $maxReads)) ||
            (($maxBases > 0) && ($bases  >= $maxBases)) ||
            (($id == $maxID))) {
            push @end, $id;

            $smallJobs++   if ($end[$nj] - $bgn[$nj] < $smallJobSize);

            #  Save the log for later printing.  We redo the configuration if there are too many small jobs.

            push @log, sprintf("--   %4u %8.2f %9u-%-9u %9u %12u %8.2f %12u %8.2f %8.2f\n",
                               $nj + 1,
                               $memory / 1024 / 1024,
                               $bgn[$nj], $end[$nj],
                               $reads, $bases,
                               ($memReads + $memBases + $memSeq) / 1024 / 1024,
                               $olaps,
                               $memOlaps / 1024 / 1024,
                               ($memAdj1 + $memAdj2 + $memWA + $memMisc) / 1024 / 1024);

            $nj++;

            $reads = 0;
            $bases = 0;
            $olaps = 0;

            push @bgn, $id + 1;  #  OEA expects inclusive ranges.
        }
    }

    #  If too many small jobs, increase memory and try again.  We'll allow any size jobs as long as
    #  there are 8 or less, but then demand there are at most 2 small jobs.

    if (($nj > 8) && ($smallJobs >= 2)) {
        my $curMem =            getGlobal("oeaMemory");
        my $newMem = int(1000 * getGlobal("oeaMemory") * 1.25) / 1000;

        print STDERR "  FAILED - configured $nj jobs, but $smallJobs jobs process $smallJobSize reads or less each.  Increasing memory from $curMem GB to $newMem GB.\n";

        setGlobal("oeaMemory", $newMem);

        goto tryOEAagain;
    }

    #  Report.

    print STDERR "--           Total                                               Reads                 Olaps  Adjusts\n";
    print STDERR "--    Job   Memory      Read Range         Reads        Bases   Memory        Olaps   Memory   Memory  (Memory in MB)\n";
    print STDERR "--   ---- -------- ------------------- --------- ------------ -------- ------------ -------- --------\n";

    foreach my $l (@log) {
        print STDERR $l;
    }

    print  STDERR "--   ---- -------- ------------------- --------- ------------ -------- ------------ -------- --------\n";
    printf(STDERR "--                                               %12u          %12u\n",
           $rlSum, $noSum);

    #  Dump a script

    open(F, "> $path/oea.sh") or caExit("can't open '$path/oea.sh' for writing: $!", undef);

    print F "#!" . getGlobal("shell") . "\n\n";
    print F "\n";
    print F getBinDirectoryShellCode();
    print F "\n";
    print F setWorkDirectoryShellCode($path);
    print F fetchStoreShellCode("unitigging/$asm.gkpStore", $path, "");
    print F fetchStoreShellCode("unitigging/$asm.ovlStore", $path, "");
    print F "\n";
    print F getJobIDShellCode();
    print F "\n";

    for (my $jj=1; $jj <= $nj; $jj++) {
        print F "if [ \$jobid = $jj ] ; then\n";
        print F "  minid=$bgn[$jj-1]\n";
        print F "  maxid=$end[$jj-1]\n";
        print F "fi\n";
    }

    print F "jobid=`printf %05d \$jobid`\n";
    print F "\n";
    print F "if [ -e ./\$jobid.oea ] ; then\n";
    print F "  echo Job previously completed successfully.\n";
    print F "  exit\n";
    print F "fi\n";
    print F "\n";
    print F fetchFileShellCode("unitigging/3-overlapErrorAdjustment", "red.red", "");
    print F "\n";
    print F "\$bin/correctOverlaps \\\n";
    print F "  -G ../$asm.gkpStore \\\n";
    print F "  -O ../$asm.ovlStore \\\n";
    print F "  -R \$minid \$maxid \\\n";
    print F "  -e " . getGlobal("utgOvlErrorRate") . " -l " . getGlobal("minOverlapLength") . " \\\n";
    print F "  -c ./red.red \\\n";
    print F "  -o ./\$jobid.oea.WORKING \\\n";
    print F "&& \\\n";
    print F "mv ./\$jobid.oea.WORKING ./\$jobid.oea\n";
    print F "\n";
    print F stashFileShellCode("$path", "\$jobid.oea", "");
    print F "\n";

    close(F);

    makeExecutable("$path/oea.sh");
    stashFile("$path/oea.sh");

  finishStage:
    emitStage($asm, "overlapErrorAdjustmentConfigure");

  allDone:
}





sub overlapErrorAdjustmentCheck ($) {
    my $asm     = shift @_;
    my $attempt = getGlobal("canuIteration");
    my $path    = "unitigging/3-overlapErrorAdjustment";

    return         if (getGlobal("enableOEA") == 0);

    goto allDone   if (fileExists("$path/oea.files"));   #  Output exists

    goto allDone   if (skipStage($asm, "overlapErrorAdjustmentCheck", $attempt) == 1);

    goto allDone   if (fileExists("unitigging/$asm.ovlStore/evalues"));   #  Stage entrely finished
    goto allDone   if (-d "unitigging/$asm.ctgStore");                    #  Assembly finished

    #  Figure out if all the tasks finished correctly.

    my $batchSize   = getGlobal("oeaBatchSize");
    my $failedJobs  = 0;
    my $numJobs     = 0;

    #  Need to read script to find number of jobs!

    my @successJobs;
    my @failedJobs;
    my $failureMessage = "";

    fetchFile("$path/oea.sh");

    open(A, "< $path/oea.sh") or caExit("can't open '$path/oea.sh' for reading: $!", undef);
    while (<A>) {
        if (m/if.*jobid\s+=\s+(\d+)\s+.*then/) {
            my $ji = substr("00000" . $1, -5);

            if (! fileExists("unitigging/3-overlapErrorAdjustment/$ji.oea")) {
                $failureMessage .= "--   job $ji.oea FAILED.\n";
                push @failedJobs, $1;
            } else {
                push @successJobs, "./$ji.oea";
            }
        }
    }
    close(A);

    #  Failed jobs, retry.

    if (scalar(@failedJobs) > 0) {

        #  If too many attempts, give up.

        if ($attempt >= getGlobal("canuIterationMax")) {
            print STDERR "--\n";
            print STDERR "-- Overlap error adjustment jobs failed, tried $attempt times, giving up.\n";
            print STDERR $failureMessage;
            print STDERR "--\n";
            caExit(undef, undef);
        }

        if ($attempt > 0) {
            print STDERR "--\n";
            print STDERR "-- Overlap error adjustment jobs failed, retry.\n";
            print STDERR $failureMessage;
            print STDERR "--\n";
        }

        #  Otherwise, run some jobs.

        emitStage($asm, "overlapErrorAdjustmentCheck", $attempt);

        submitOrRunParallelJob($asm, "oea", $path, "oea", @failedJobs);
        return;
    }

  finishStage:
    print STDERR "-- Found ", scalar(@successJobs), " overlap error adjustment output files.\n";

    open(L, "> $path/oea.files") or caExit("can't open '$path/oea.files' for writing: $!", undef);
    foreach my $f (@successJobs) {
        print L "$f\n";
    }
    close(L);

    stashFile("$path/oea.files");

    emitStage($asm, "overlapErrorAdjustmentCheck");

  allDone:
}




sub updateOverlapStore ($) {
    my $asm     = shift @_;
    my $bin     = getBinDirectory();
    my $cmd;
    my $path    = "unitigging/3-overlapErrorAdjustment";

    return         if (getGlobal("enableOEA") == 0);

    goto allDone   if (skipStage($asm, "updateOverlapStore") == 1);

    goto allDone   if (fileExists("unitigging/$asm.ovlStore/evalues"));   #  Stage entrely finished
    goto allDone   if (-d "unitigging/$asm.ctgStore");                    #  Assembly finished

    fetchFile("unitigging/3-overlapErrorAdjustment/oea.files");

    caExit("didn't find '$path/oea.files' to add to store, yet jobs claim to be finished", undef)  if (! -e "$path/oea.files");

    open(F, "< $path/oea.files");
    while (<F>) {
        chomp;
        fetchFile("$path/$_");
    }
    close(F);

    fetchStore("unitigging/$asm.ovlStore");

    $cmd  = "$bin/loadErates \\\n";
    $cmd .= "  -G ../$asm.gkpStore \\\n";
    $cmd .= "  -O ../$asm.ovlStore \\\n";
    $cmd .= "  -L ./oea.files \\\n";
    $cmd .= "> ./oea.apply.err 2>&1";

    if (runCommand($path, $cmd)) {
        unlink "unitigging/$asm.ovlStore/evalues";
        caExit("failed to add error rates to overlap store", "$path/oea.apply.err");
    }

    stashFile("unitigging/$asm.ovlStore/evalues");

    my $report = "-- No report available.\n";

    #open(F, "< $path/oea.apply.stats") or caExit("Failed to open error rate adjustment statistics in '$path/oea.apply.stats': $!", undef);
    #while (<F>) {
    #}
    #close(F);

    addToReport("adjustments", $report);

  finishStage:
    emitStage($asm, "updateOverlapStore");

  allDone:
}
