#!/usr/bin/perl

use XML::Simple;
use Data::Dumper;
use Getopt::Long;
use Cwd;
use URI::Escape;

$NOWHERE = "<<<SOMEWHERE-OUTSIDE-THE-TREE>>>";

# safeExec
#
# This is a safe form of the backtick operator

sub safeExec(@) {
    my ($pid, $data);
    local *CHILD;
    $ChildDied = 0;

    die "Can't fork: $!\n" unless (defined($pid = open(CHILD, "-|")));
    if ($pid) { # parent
        
        while (<CHILD>) {
            $data .= $_;
        }
        close CHILD;
    }
    else {
        open(STDERR, ">&STDOUT") or die "Can't dup stderr to stdout! ($!)\n";
        exec @_
            or die "Can't exec command ($!)\n";
    }
    
    return $data;
}

sub svn {
    my @args = @_;
    unshift(@args, "svn");
    print ">> @args\n";
    my $result = safeExec(@args);
    if ($? != 0) {
        die "$0: Command failed: $result\n";
    }
    $result;
}

sub parseHistory {
    my ($xml, $root, $savePaths) = @_;
    my %history;
    
    my $parseTree = XMLin($xml, ForceArray => ['path', 'logentry', 'revprops', 'property']);
    
    foreach my $entry (@{$parseTree->{'logentry'}}) {
        my $revno = $entry->{'revision'};
        
        if (ref($entry->{'msg'}) eq '') {
            $history{$revno}{msg} = $entry->{'msg'};
        }
        else {
            # An empty message shows up as an empty hash
            $history{$revno}{msg} = '';
        }
        $history{$revno}{copy} = [];
        $history{$revno}{A} = [];
        $history{$revno}{M} = [];
        $history{$revno}{D} = [];
        $history{$revno}{R} = [];
        $history{$revno}{common} = '';
        
        $history{$revno}{revprops}{'svn:author'} = $entry->{'author'};
        $history{$revno}{revprops}{'svn:date'} = $entry->{'date'};
        foreach my $rp (@{$entry->{revprops}}) {
            foreach $prop (keys(%{$rp->{property}})) {
                $history{$revno}{revprops}{$prop} = $rp->{property}{$prop}{content};
            }
        }

        foreach my $path (@{$entry->{'paths'}{'path'}}) {
            if (defined($path->{'copyfrom-path'})) {
                my $from = $path->{'copyfrom-path'};
                my $to = $path->{'content'};
                my $skipSaveAction = 0;
                
                if ($from =~ s!^$root/!/!) {
                    if ($to =~ s!^$root/!/!) {
                        push(@{$history{$revno}{copy}}, { 'from' => $from, 'to' => $to, 'rev' => $path->{'copyfrom-rev'} });
                        $history{$revno}{common} = longestCommonPath($history{$revno}{common}, $to);
                        $history{$revno}{common} = longestCommonPath($history{$revno}{common}, $from);
                    }
                    else {
                        print "Warning: Copy to path outside tree ($to) ignored\n";
                        push(@{$history{$revno}{copy}}, { 'from' => $from, 'to' => $NOWHERE, 'rev' => $path->{'copyfrom-rev'} });
                    }
                }
                else {
                    print "Warning: Copy from a path outside tree ($from) will result in complete addition\n";
                    $to =~ s!^$root/!/!;
                    push(@{$history{$revno}{copy}}, { 'to' => $to });
                }
                if ($path->{'action'} ne 'R') {
                    $skipSaveAction++;
                }
            }
            
            if ($savePaths && !$skipSaveAction) {
                my $relPath = $path->{'content'};
                $relPath =~ s!^$root/?\b!/!;
                push(@{$history{$revno}{$path->{'action'}}}, $relPath);
                $history{$revno}{common} = longestCommonPath($history{$revno}{common}, $relPath);
            }
        }
    }
    
    \%history;
}

sub longestCommonPath {
    my ($a, $b) = @_;
    my $longest;
    
    if ($a eq '') {
        $a = $b;
    }
    elsif ($b eq '') {
        $b = $a;
    }
    my @aParts = split('/', $a);
    my @bParts = split('/', $b);
    my $i;
    my @longest = ();
    for ($i = 0; $i <= $#aParts; $i++) {
        if ($aParts[$i] eq $bParts[$i]) {
            push(@longest, $aParts[$i]);
        }
        else {
            last;
        }
    }

    my $result = join('/', @longest);
    $result = "./" if ($result eq '');
    $result;
}

sub loadHistory {
    my ($repo, $lower, $upper, $root, $savePaths) = @_;
    my $xml = svn("log", "--xml", "--verbose", "--with-all-revprops", "-r", "$lower:$upper", $repo);
    my $history = parseHistory($xml, $root, $savePaths);
    
    $history;
}

sub loadRevisionMap {
    my $fh;
    
    if (-f $REVISION_MAP) {
        die "$0: Can't open revision map '$REVISION_MAP' ($!)\n" unless (open($fh, $REVISION_MAP));
        while (<$fh>) {
            chomp;
            my ($local, $remote) = split(' ');
            $RevisionMap{'local'}{$local} = $remote;
            $RevisionMap{'remote'}{$remote} = $local;
        }
    }
}

sub latestCommit {
    svn("update", "--depth", "empty", @_) unless ($_[0] =~ m!^\w+://!);
    my $xml = svn("info", "--xml", @_);
    my $parseTree = XMLin($xml);
    $parseTree->{'entry'}{'commit'}{'revision'};
}

sub getRoot {
    my ($url) = @_;
    my $xml = svn("info", "--xml", $url);
    my $parseTree = XMLin($xml);
    my $result = $parseTree->{'entry'}{'url'};
    my $rootUrl = $parseTree->{'entry'}{'repository'}{'root'};
    $result =~ s/^\Q$rootUrl\E//;

    $result;
}

sub historyRevisions {
    my ($history) = @_;
    sort {$a <=> $b} (keys(%{$history}));
}

sub saveRevisionMap() {
    my $fh;
    
    die "$0: Can't open revision map '$REVISION_MAP' ($!)\n" unless (open($fh, ">$REVISION_MAP"));
    foreach my $rev (sort {$a <=> $b} (keys(%{$RevisionMap{'local'}}))) {
        print $fh "$rev\t$RevisionMap{'local'}{$rev}\n";
    }
    close($fh);
}

sub updateRevisionMap {
    my ($local, $remote, $append) = @_;
    my $fh;

    $RevisionMap{'local'}{$local} = $remote;
    $RevisionMap{'remote'}{$remote} = $local;
    
    if ($append) {
        die "$0: Can't open revision map '$REVISION_MAP' ($!)\n" unless (open($fh, ">>$REVISION_MAP"));
        print $fh "$local\t$remote\n";
        close($fh);
    }
}

sub localRevisionFor {
    my ($rev) = @_;
    my $localRev;
    
    if (defined($RevisionMap{'remote'}{$rev})) {
        $localRev = $RevisionMap{'remote'}{$rev};
    }
    else {
        warn "$0: Remote revision $rev has no known local equivalent, finding nearest\n";
        while ($rev > 0 && !defined($RevisionMap{'remote'}{$rev})) {
            $rev--;
        }
        $localRev = $RevisionMap{'remote'}{$rev};
    }
    
    $localRev;
}

sub cleanupWc {
    my $dir = shift;
    svn("cleanup", $dir);
    svn("revert", "--recursive", $dir);
    my $statusXml = svn("status", "--xml", $dir);
    my $tree = XMLin($statusXml, ForceArray => ['entry']);

    foreach my $entry (@{$tree->{'target'}{'entry'}}) {
        if ($entry->{'wc-status'}{'item'} eq 'unversioned') {
            print "> Removing unversioned file $entry->{'path'}\n";
            safeExec("rm", "-rf", $entry->{'path'});
        }
    }
}

sub getProperties {
    my $file = shift;
    my $xml = svn("proplist", "-v", "--xml", $file);
    my $tree = XMLin($xml, ForceArray => ['property']);
    my %props;

    foreach $property (keys(%{$tree->{'target'}{'property'}})) {
        $props{$property} = $tree->{'target'}{'property'}{$property}{'content'};
    }
    
    %props;
}

sub setProperties {
    my $file = shift;
    my %props = @_;
    
    foreach my $property (keys(%props)) {
        svn("propset", "--force", $property, $props{$property}, $file);
    }
}

sub revpropMustBeCopied {
    my $revprop = shift;
    my $result = 0;
    
    $result++ if ($CopyRevprop{$revprop});
    if ($CopyRevprop{all} || $CopyRevprop{ALL}) {
        $result++ unless ($CopyRevprop{"!$revprop"} || $CopyRevprop{"^$revprop"});
    }
    
    $result;
}

sub urlIsRepoRoot {
    my $url = shift;
    my $xml = svn("info", "--xml", $url);
    my $tree = XMLin($xml);
    
    $tree->{entry}{url} eq $tree->{entry}{repository}{root};
}

sub canonicalise {
    my $path = shift;
    
    1 while ($path =~ s!\/\.\/!/!g);
    1 while ($path =~ s![^:]\K//!/!g);
    
    $path;
}

sub escapeAt {
    my $path = shift;
    if ($path =~ /\@/) {
        # '@' added at the end to avoid svn interpreting embedded
        # @ characters as revision specifiers
        $path .= '@';
    }
    $path;
}

###
### Main Code
###

$DestWorkingDir = undef;
$SrcWorkingDir = undef;
$doCopyRevprops ='';
$RetryCommit = 0;
$UseStatusRevprop = 0;
$SkipCleanup = 0;
$EndRevision = 'HEAD';

GetOptions(
            "target-working-dir|w=s" => \$DestWorkingDir,
            "copy-revprops|p=s" => \$doCopyRevprops,
            "retry-commit|c" => \$RetryCommit,
            "source-working-dir|s=s" => \$SrcWorkingDir,
            "use-status-revprop|u" => \$UseStatusRevprop,
            "skip-cleanup" => \$SkipCleanup,
            "end-revision|r=s" => \$EndRevision,
          );
          
die "Usage: $0 [options] source-url target-url\n" unless ($#ARGV == 1);

if ($doCopyRevprops ne '') {
    $UseStatusRevprop++;
    foreach my $prop (split(',', $doCopyRevprops)) {
        $CopyRevprop{$prop}++;
    }
}

$SourceURL = shift;
$TargetURL = shift;

$TargetURL =~ s!/+$!!;
unless (defined($DestWorkingDir)) {
    $DestWorkingDir = (split('/', $TargetURL))[-1];
    $DestWorkingDir .= "_mirror_dst";
    $DestWorkingDir = getcwd() . "/" . $DestWorkingDir;
}
$REVISION_MAP = "$DestWorkingDir/.svn/svnmirror-revision-map";

unless (defined($SrcWorkingDir)) {
    $SrcWorkingDir = (split('/', $TargetURL))[-1];
    $SrcWorkingDir .= "_mirror_src";
    $SrcWorkingDir = getcwd() . "/" . $SrcWorkingDir;
}

print "Target Working directory: $DestWorkingDir\n";
unless (-d $DestWorkingDir) {
    print "Directory does not exist, doing fresh checkout\n";
    $msg = svn("checkout", $TargetURL, $DestWorkingDir);
    die "$0: Failed to check out working copy ($@): $msg\n" unless ($? == 0);
}

print "Loading local history ...\n";
$LocalHistory = loadHistory($DestWorkingDir, 0, 'HEAD', '', 0);
@localRevs = historyRevisions($LocalHistory);

# If the local URL isn't the repo root then the first entry will be the
# creation of the top-level directory, in which case we must discard this one.
shift(@localRevs) unless (urlIsRepoRoot($TargetURL));

loadRevisionMap();
$wcVersion = latestCommit($DestWorkingDir);
if ($wcVersion > 0 && !defined($RevisionMap{'local'}{$wcVersion})) {
    print "Warning: Revision map cache is corrupted, discarding\n";
    %RevisionMap = ();
    $lowerBound = 0;
}
else {
    $lowerBound = $RevisionMap{'local'}{$wcVersion} + 1;
}

print "Finding latest remote version ...\n";
$latestRemote = latestCommit($SourceURL);
if ($latestRemote < $lowerBound) {
    print "Latest remote revision is $latestRemote, mirror is up to date\n";
    exit 0;
}

print "Loading remote history from revision $lowerBound to $EndRevision...\n";
$RemoteHistory = loadHistory($SourceURL, $lowerBound, $EndRevision, getRoot($SourceURL), 1);
@remoteRevs = historyRevisions($RemoteHistory);

# If the remote URL isn't the repo root, and we're not loading a partial history,
# then the first entry will be the creation of the top-level directory, in which
# case we must discard this one.
shift(@remoteRevs) if ($lowerBound == 0 && !urlIsRepoRoot($SourceURL));

# Rebuild the revision map
if ($lowerBound == 0 && $#localRevs >= 0) {
    die "$0: Fewer remote revisions found than existing local ones ($#remoteRevs < $#localRevs)\n" if ($#remoteRevs < $#localRevs);
    foreach my $local (@localRevs) {
        my $remote = shift(@remoteRevs);
        updateRevisionMap($local, $remote, 0);
    }
}

print "Source working directory: $SrcWorkingDir\n";
unless (-d $SrcWorkingDir) {
    print "Directory does not exist, doing fresh checkout at revision $remoteRevs[0]\n";
    $msg = svn("checkout", "-r", "$remoteRevs[0]", $SourceURL, $SrcWorkingDir);
    die "$0: Failed to check out working copy ($@): $msg\n" unless ($? == 0);
}

if (!$RetryCommit && !$SkipCleanup) {
    print "Cleaning working copies\n";
    cleanupWc($DestWorkingDir);
    cleanupWc($SrcWorkingDir);
}

# Reset the revision map now
saveRevisionMap();

foreach $rev (@remoteRevs) {
    print "> Processing remote revision $rev\n";
    
    my $commonRoot = '';
    
    if ($RetryCommit) {
        print ">> Retrying commit with current state\n";
    }
    else {
        $commonRoot = $RemoteHistory->{$rev}{common};
        $commonRoot =~ s!/[^/]*$!/! unless (-d "$SrcWorkingDir/$commonRoot");
        $commonRoot = canonicalise($commonRoot);
        
        svn('update', '-r', 'HEAD', escapeAt(canonicalise("$DestWorkingDir/$commonRoot")));
        print svn('update', '-r', $rev, canonicalise("$SrcWorkingDir/$commonRoot"));

        # Handle replaces first (delete the file prior to copy)
        foreach my $del (sort {$b cmp $a} (@{$RemoteHistory->{$rev}{'R'}})) {
            print "> Replacing $del\n";
            my $togo = canonicalise("$DestWorkingDir/$del");
            svn("remove", "--force", escapeAt($togo)) if (-e $togo);
        }
                
        # Sort copies lexicographically to ensure higher paths created first
        foreach my $copy (sort {$a->{'to'} cmp $b->{'to'}} (@{$RemoteHistory->{$rev}{copy}})) {
            my $from = "." . $copy->{'from'};
            my $to = "." . $copy->{'to'};
            my $srcFrom = canonicalise("$SrcWorkingDir/$from");
            my $srcTo = canonicalise("$SrcWorkingDir/$to");
            my $destFrom = canonicalise("$DestWorkingDir/$from");
            my $destTo = canonicalise("$DestWorkingDir/$to");
            my $rev = localRevisionFor($copy->{'rev'});
            if ($copy->{'from'} eq '') {
                # Import from outside the tree
                print "> Copy to $to from outside the tree\n";
                svn("export", escapeAt("$srcTo"), "$destTo");
                svn("add", "--parents", escapeAt("$destTo"));
                ### TODO: Handle properties on copied-in files
            }
            elsif ($copy->{'to'} ne $NOWHERE) {
                # Handle destination being an already existing file
                print "> Copy to $to from $from\n";
                if (-f $destTo) {
                    svn("remove", "--force", escapeAt("$destTo"));
                }
                # Maybe restoring from a previously deleted revision, if so
                # we'll have to copy from the respository
                if (!-e $destFrom) {
                    $destFrom = $TargetURL . join('/', map { uri_escape($_); } split('/', $copy->{'from'}));
                }
                svn('copy', "--parents", "$destFrom\@$rev", "$destTo");
                # May be a modify of a file as well as a rename, so copy over
                # the source file too!
                if (-f "$SrcWorkingDir/$to") {
                    print ">> cp -f $srcTo $destTo\n";
                    safeExec("cp", "-f", "$srcTo", "$destTo");
                    setProperties(escapeAt("$destTo"), getProperties(escapeAt("$srcTo")));
                }
            }
        }
        
        # Now handle all adds/modifies/deletes

        foreach my $add (sort(@{$RemoteHistory->{$rev}{'A'}})) {
            print "> Adding $add\n";
            my $srcAdd = canonicalise("$SrcWorkingDir/$add");
            my $destAdd = canonicalise("$DestWorkingDir/$add");
            if (-d $srcAdd) {
                if (! -d "$destAdd/.svn") {
                    svn("mkdir", "--parents", escapeAt($destAdd));
                }
                else {
                    print "($destAdd is already under source control)\n";
                }
            }
            else {
                safeExec("cp", $srcAdd, $destAdd);
                svn("add", "--parents", escapeAt($destAdd));
            }
            setProperties(escapeAt($destAdd), getProperties(escapeAt($srcAdd)));
        }

        foreach my $del (sort {$b cmp $a} (@{$RemoteHistory->{$rev}{'D'}})) {
            print "> Removing $del\n";
            my $togo = canonicalise("$DestWorkingDir/$del");
            svn("remove", "--force", escapeAt($togo)) if (-e $togo);
        }        

        foreach my $mod (sort(@{$RemoteHistory->{$rev}{'M'}})) {
            print "> Updating $mod\n";
            my $srcMod = canonicalise("$SrcWorkingDir/$mod");
            my $destMod= canonicalise("$DestWorkingDir/$mod");
            if (! -d $srcMod) {
                print ">> cp -f $srcMod $destMod\n";
                safeExec("cp", "-f", $srcMod, $destMod);
            }
            setProperties(escapeAt($destMod), getProperties(escapeAt($srcMod)));
        }        
    }
    
    my $msg = $RemoteHistory->{$rev}{'msg'};
    if (!$UseStatusRevprop) {
        $msg .= "\nAuthor: $RemoteHistory->{$rev}{revprops}{'svn:author'}\nDate: $RemoteHistory->{$rev}{revprops}{'svn:date'}\nRevision: $rev";
    }
    
    print svn('commit', '-m', $msg, escapeAt(canonicalise("$DestWorkingDir/$commonRoot")));
    
    my $newRev = latestCommit($DestWorkingDir);
    print "> Local revision $newRev created\n";
    
    updateRevisionMap($newRev, $rev, 1);
    
    foreach my $revprop (keys(%{$RemoteHistory->{$rev}{revprops}})) {
        if (revpropMustBeCopied($revprop)) {
            svn("propset", "--force", $revprop, "--revprop", "--revision", $newRev,
                $RemoteHistory->{$rev}{revprops}{$revprop}, "$DestWorkingDir");
        }
    }
    
    if ($UseStatusRevprop) {
        svn("propset", "--force", "svnmirror:info", "--revprop", "--revision", $newRev,
                "$rev/$RemoteHistory->{$rev}{revprops}{'svn:date'}", "$DestWorkingDir");
    }
        
    $RetryCommit = 0;
}

# Rewrite full revision map on successful completion
saveRevisionMap();


