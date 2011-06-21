#!/usr/bin/perl

use XML::Simple;
use Data::Dumper;

die "Usage: $0 original-xml-svn-ls new-xml-svn-ls\n" unless ($#ARGV == 1);

print STDERR "Loading $ARGV[0] ...\n";

my $origXml = XMLin($ARGV[0]);

foreach my $path (keys(%{$origXml->{list}{entry}})) {
	my $entry = $origXml->{list}{entry}{$path};
	addPaths($path, $entry->{kind});
}

print STDERR "Loading $ARGV[1] ...\n";

my $newXml = XMLin($ARGV[1]);

print STDERR "Generating mapping ...\n";

foreach my $path (sort(keys(%{$newXml->{list}{entry}}))) {
	my $entry = $newXml->{list}{entry}{$path};
	my @matches = findBestMatches($path, $entry->{kind});
	
	print $path;
	if ($#matches > 2) {
		print "\t<MANY>";
	}
	else {
		my $count = 0;
		foreach my $match (@matches) {
			if ($match ne '') {
				$seen{$match}++;
				print "\t$match";
				$count++;
			}
		}
		print "\t<NEW>" unless ($count);
	}
	print "\n";
}

foreach my $path (sort(keys(%{$origXml->{list}{entry}}))) {
	print "MISSING\t$path\n" unless ($seen{$path});
}

print STDERR "Done.\n";

sub addPaths {
	my ($fullPath, $kind) = @_;
	my @pathSet = genPaths($fullPath, $kind);
	
	foreach my $path (@pathSet) {
		do {
			if (defined($SourcePath{"$kind:$path"})) {
				push(@{$SourcePath{"$kind:$path"}}, $fullPath);
			}
			else {
				@{$SourcePath{"$kind:$path"}} = ($fullPath);
			}
		}
		while ($path =~ s!^[^/]*/!!);
	}
}

sub findBestMatches {
	my ($fullPath, $kind) = @_;
	my @pathSet = genPaths($fullPath, $kind);

	foreach my $path (@pathSet) {
		do {
			return @{$SourcePath{"$kind:$path"}} if (defined($SourcePath{"$kind:$path"}));
		}
		while ($path =~ s!^[^/]*/!!);
	}
	
	return ();
}

sub genPaths {
	my ($path, $kind) = shift;
	my @pathSet;
	
	$path = lc($path);
	push(@pathSet, $path);
	
	if ($kind ne 'dir') {
		my $pkg = $path;
		$pkg =~ s/_specs?(_?\d+)?\.(sql|pls)$/\1.pks/i;
		$pkg =~ s/_body(_?\d+)?\.(sql|pls)$/\1.pkb/i;
		push(@pathSet, $pkg) unless ($pkg eq $path || $pkg eq '');
		
		my $noext = $path;
		$noext =~ s!\w+\K\.\w+$!!;
		push(@pathSet, $noext) unless ($noext eq $path || $noext eq '');
	}
	
	@pathSet;
}
