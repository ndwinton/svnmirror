#!/usr/bin/perl

use Data::Dumper;
use Getopt::Long;
use Cwd;

$REVISION_MAP = "./.svn/svnmirror-revision-map";
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

# parseXml(xmldata)
#
# VERY simplistic XML parser, good enough to convert overall structure
# into a hashmap/array structure to allow traversal and extraction of sub-elements

sub parseXml {
    my ($data) = @_;
    my (%result, $tag, $attrs, $body);
    $@ = '';
    
    # Remove <?xml ...> line
    $data =~ s/^\s*<\?xml[^>]*>//s;
    
    # uin until we have nothing but spaces, if that
    while ($data !~ /^\s*$/s) {
    
        # Strip the opening tag (alphanumerics and colon to include any
        # namespace. It will be left in $1.
        if ($data =~ s/^\s*<([a-zA-Z0-9_\-:]+)([^>]*)>//s) {
        
            # Save the tag name and attributes
            $tag = $1;
            $attrs = $2;
            
            # Match everything up until the nearest closing tag.
            # See http://docstore.mik.ua/orelly/perl/cookbook/ch06_16.htm for
            # an idea of why we use this horrible nested negative lookahead
            # construction ... but basically it's needed for speed.
            if ($data =~ s/^((?:(?!<\/$tag>).)*)<\/$tag>\s*//s) {
                $body = $1;

                # Now strip the namespace from the tag
                $tag =~ s/^[^:]+://;

                my $child = $body;
                # If element contains sub-elements then we need to parse deeper
                if ($body =~ /^\s*</s) {
                    $child = parseXml($body);
                }
                else {
                    # Basic unquoting ...
                    $body =~ s/\&lt;/</g;
                    $body =~ s/\&gt;/>/g;
                    $body =~ s/\&amp;/\&/g;
                    $child = { '$text' => $body };
                }

                # Add attributes, if any
                addAttrs($attrs, $child);
                
                # reference to hold (potential) multiple children.
                if (!defined($result{$tag})) {
                    # Initial element, set up array
                    $result{$tag}[0] = $child;
                }
                else {
                    # Subsequent values
                    push(@{$result{$tag}}, $child);
                }
                
            }
            else {
                $@ = "Unparseable XML data - unclosed '$tag' tag?: $data\n";
                return undef;
            }
        }
        else {
            $@ = "Unparseable XML data: $data\n";
            $data = '';
            return undef;
        }
    }
    
    return \%result;
}

sub addAttrs($$) {
    my ($text, $child) = @_;
    
    while ($text =~ s/^\s*([^'"]+)=[\"\']([^\"\']*)[\"\']//s) {
        my $attr = $1;
        my $val = $2;
        $child->{"\@$attr"} = $val;
    }
}

sub svn {
    print ">> svn @_\n";
    my $result = safeExec("svn", @_);
    if ($? != 0) {
        die "$0: Command failed: $result\n";
    }
    $result;
}

sub parseHistory {
    my ($xml, $root, $savePaths) = @_;
    my %history;
    
    my $parseTree = parseXml($xml);
    
    foreach my $entry (@{$parseTree->{'log'}[0]{'logentry'}}) {
        my $revno = $entry->{'@revision'};
        
        $history{$revno}{author} = $entry->{'author'}[0]{'$text'};
        $history{$revno}{msg} = $entry->{'msg'}[0]{'$text'};
        $history{$revno}{date} = $entry->{'date'}[0]{'$text'};
        $history{$revno}{copy} = [];
        foreach my $path (@{$entry->{'paths'}[0]{'path'}}) {
            my $skip = 0;
            if (defined($path->{'@copyfrom-path'})) {
                my $from = $path->{'@copyfrom-path'};
                my $to = $path->{'$text'};

                if ($from =~ s!^$root/!/!) {
                    if ($to =~ s!^$root/!/!) {
                        push(@{$history{$revno}{copy}}, { 'from' => $from, 'to' => $to, 'rev' => $path->{'@copyfrom-rev'} });
                    }
                    else {
                        print "Warning: Copy to path outside tree ($to) ignored\n";
                        push(@{$history{$revno}{copy}}, { 'from' => $from, 'to' => $NOWHERE, 'rev' => $path->{'@copyfrom-rev'} });
                        $skip++;
                    }
                }
                else {
                    print "Warning: Copy from a path outside tree ($from) will result in complete addition\n";
                }
            }
            if ($savePaths) {
                my $relPath = $path->{'$text'};
                $relPath =~ s!^$root/!/!;
                $history{$revno}{'paths'}{$relPath} = $path->{'@action'} unless ($skip);
            }
        }
    }
    
    \%history;
}

sub revisionRange {
    my ($history) = @_;
    
    my @revs = sort {$a <=> $b} (keys(%{$history}));
    $revs[0] = 0 unless ($revs[0]);
    ($revs[0], $revs[-1]);
}

sub loadHistory {
    my ($repo, $lower, $upper, $root, $savePaths) = @_;
    my $xml = svn("log", "--xml", "--verbose", "-r", "$lower:$upper", $repo);
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

sub wcVersion {
    svn("update");
    my $xml = svn("info", "--xml");
    my $parseTree = parseXml($xml);
    $parseTree->{'info'}[0]{'entry'}[0]{'@revision'};
}

sub getRoot {
    my ($url) = @_;
    my $xml = svn("info", "--xml", $url);
    my $parseTree = parseXml($xml);
    my $result = $parseTree->{'info'}[0]{'entry'}[0]{'url'}[0]{'$text'};
    my $rootUrl = $parseTree->{'info'}[0]{'entry'}[0]{'repository'}[0]{'root'}[0]{'$text'};
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
    svn("cleanup");
    svn("revert", "--recursive", ".");
    my $statusXml = svn("status", "--xml");
    my $tree = parseXml($statusXml);

    foreach my $entry (@{$tree->{'status'}[0]{'target'}[0]{'entry'}}) {
        if ($entry->{'wc-status'}[0]{'@item'} eq 'unversioned') {
            print "> Removing unversioned file $entry->{'@path'}\n";
            safeExec("rm", "-rf", $entry->{'@path'});
        }
    }
}

sub fixSvnIgnoreProperties {

    my $statusXml = svn("status", "--xml");
    my $tree = parseXml($statusXml);

    foreach my $entry (@{$tree->{'status'}[0]{'target'}[0]{'entry'}}) {
        if ($entry->{'wc-status'}[0]{'@item'} ne 'deleted') {
            my $path = $entry->{'@path'};
            my $prop = svn("propget", "svn:ignore", $path);
            if ($prop ne '') {
                print ">>> Sanitising svn:ignore on $path\n";
                $prop =~ s/\r//gs;
                svn("propset", "svn:ignore", $prop, $path);
            }
        }
    }
}

sub recreateLocalFromRemote {
    my ($rev, $path) = @_;
    $path =~ s!^/!!;
    
    my $data = svn("cat", "-r", $rev, "$SourceURL/$path\@$rev");
    my $fh;
    die "$0: Can't overwrite '$path' ($1)\n" unless open($fh, ">$path");
    print $fh $data;
    close($fh);
}

sub resolveConflicts {
    my ($rev, $history) = @_;
    my $statusXml = svn("status", "--xml");
    my $tree = parseXml($statusXml);
    
    # Look for conflicts and try to resolve
    foreach my $entry (@{$tree->{'status'}[0]{'target'}[0]{'entry'}}) {
        if ($entry->{'wc-status'}[0]{'@tree-conflicted'} eq 'true') {
            my $path = $entry->{'@path'};
            if ($history->{$rev}{'paths'}{"/$path"} eq 'D') {
                print ">>> Resolving conflict for $path -- deleting\n";
                svn("rm", "--force", $path);
            }
            elsif (-f $path) {
                print ">>> Resolving conflict for $path -- overwriting local\n";
                recreateLocalFromRemote($rev, $path);
            }
            elsif (-e $path) {
                print ">>> Resolving conflict for $path -- accepting local\n";
            }            else {
                die "$0: $path missing when trying to resolve conflict\n";
            }
        }
    }
    
    # Check all additional files for consistency, add and delete as appropriate
    foreach my $path (sort(keys(%{$history->{$rev}{'paths'}}))) {
        my $state = $history->{$rev}{'paths'}{$path};
        $path =~ s!^/!!;
        
        if ($state eq 'A' && ! -e $path) {
            recreateLocalFromRemote($rev, $path);
            svn("add", $path);
        }
        elsif ($state eq 'D' && -e $path) {
            svn("rm", "--force", $path);
        }
    }
    svn('resolve', '--non-interactive', '--accept=working', '--recursive', '.');
}

###
###
###

$WorkingDir = undef;
$FixRevprops = 0;
$RetryCommit = 0;

GetOptions(
            "working-dir|w=s" => \$WorkingDir,
            "fix-revprops|p" => \$FixRevprops,
            "retry-commit|r" => \$RetryCommit,
          );
          
die "Usage: $0 [options] source-url target-url\n" unless ($#ARGV == 1);

$SourceURL = shift;
$TargetURL = shift;

$TargetURL =~ s!/+$!!;
unless (defined($WorkingDir)) {
    $WorkingDir = (split('/', $TargetURL))[-1];
    $WorkingDir .= "_svnmirror_";
    $WorkingDir = getcwd() . "/" . $WorkingDir;
}

print "Working directory: $WorkingDir\n";
unless (-d $WorkingDir) {
    print "Directory does not exist, doing fresh checkout\n";
    $msg = svn("checkout", $TargetURL, $WorkingDir);
    die "$0: Failed to check out working copy ($@): $msg\n" unless ($? == 0);
}
chdir($WorkingDir);

if (!$RetryCommit) {
    print "Cleaning working copy\n";
    cleanupWc();
}

print "Loading local history ...\n";
$LocalHistory = loadHistory(".", 0, 'HEAD', '', 0);
@localRevs = historyRevisions($LocalHistory);

loadRevisionMap();
$wcVersion = wcVersion();
if ($wcVersion > 0 && !defined($RevisionMap{'local'}{$wcVersion})) {
    print "Warning: Revision map cache is corrupted, discarding\n";
    %RevisionMap = ();
    $lowerBound = 0;
}
else {
    $lowerBound = $RevisionMap{'local'}{$wcVersion} + 1;
}


print "Loading remote history from revision $lowerBound ...\n";
$RemoteHistory = loadHistory($SourceURL, $lowerBound, 'HEAD', getRoot($SourceURL), 0);
@remoteRevs = historyRevisions($RemoteHistory);

# If the remote URL isn't the repo root then the first entry will be the creation of the
# top-level directory, in which case we must discard this one.
shift(@remoteRevs) if ($remoteRevs[0] != 1);
 
# Rebuild the revision map
if ($lowerBound == 0 && $#localRevs >= 0) {
    die "$0: Fewer remote revisions found than existing local ones ($#remoteRevs < $#localRevs)\n" if ($#remoteRevs < $#localRevs);
    foreach my $local (@localRevs) {
        my $remote = shift(@remoteRevs);
        updateRevisionMap($local, $remote, 0);
    }
}

# Reset the revision map now
saveRevisionMap();

foreach $rev (@remoteRevs) {
    print "> Processing remote revision $rev\n";
    
    if ($RetryCommit) {
        print ">> Retrying commit with current state\n";
    }
    else {
        svn('update');
        # Sort copies lexicographically to ensure higher paths created first
        foreach my $copy (sort {$a->{'to'} cmp $b->{'to'}} (@{$RemoteHistory->{$rev}{copy}})) {
            my $from = "." . $copy->{'from'};
            my $to = "." . $copy->{'to'};
            my $rev = localRevisionFor($copy->{'rev'});
            unless ($copy->{'to'} eq $NOWHERE) {
                # Handle destination being an already existing file
                if (-f $to) {
                    svn("rm", "--force", $to);
                }
                svn('copy', "--parents", "$from\@$rev", "$to") unless ($copy->{'to'} eq $NOWHERE);
            }
        }
        
        print svn('merge', '-c', $rev, '--non-interactive', '--accept=theirs-full', "$SourceURL/\@$rev");
    }
    
    my $msg = $RemoteHistory->{$rev}{'msg'};

    if (!$FixRevprops) {
        $msg .= "\nAuthor: $RemoteHistory->{$rev}{'author'}\nDate: $RemoteHistory->{$rev}{'date'}\n";
    }
    
    eval {
        print svn('commit', '-m', $msg);
    };
    
    if ($@ ne '') {
        if ($@ =~ /Cannot accept non-LF line endings in 'svn:ignore' property/) {
            print ">> Commit failed because of non-LF endings in svn:ignore property -- attempting fix\n";
            fixSvnIgnoreProperties();
        }
        elsif ($@ =~ /remains in conflict/) {
            resolveConflicts($rev, loadHistory($SourceURL, $rev, $rev, getRoot($SourceURL), 1));
        }
        # Try again, last chance
        print svn('commit', '-m', $msg);
    }
    
    my $newRev = wcVersion();
    print "> Local revision $newRev created\n";
    
    updateRevisionMap($newRev, $rev, 1);
    
    if ($FixRevprops) {
        svn("propset", "svn:author", "--revprop", "--revision", $newRev, $RemoteHistory->{$rev}{'author'}, ".");
        svn("propset", "svn:date", "--revprop", "--revision", $newRev, $RemoteHistory->{$rev}{'date'}, ".");
    }
    
    $RetryCommit = 0;
}

# Rewrite full revision map on successful completion
saveRevisionMap();


