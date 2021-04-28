#!/usr/bin/perl
=pod

This script:
1. watches indefinitely log files like tail -f 
2. joins record from them to stdout in convenient format
3. colors different level of log messages to easily catch errors, etc.
4. marks each line with tiny prefix for easily identifying of the source for that line

You can:
- extract values of fields from JSON output or from Field="Value" output 
- use only some of fields to produce output
- preprocess value of the field before including it to output
- Decide whether to include/exclude particular line based on the value of fields

All script configuration except of the set of the input files is configured by modifying source code.
This allows script to keep singularity and to be easier to understand and more flexible in functionality

=cut

use strict;
use warnings;
use JSON;
use Time::HiRes qw(time usleep gettimeofday);
use Data::Dumper;
use Term::ANSIColor;

# interval in microseconds (10e-6 - one milllions of second)
my $wait_file = 10_000; # wait 0.01s before checking next file
my $wait_iteration = 100_000; # wait 0.1s before next iteration over files

# outputs to terminal lines with corresponsding level in custom colors. default - reset
my $level_color = {'error' => 'bold red', 'trace' => 'yellow', 'info'=>'blue'}; 
# color to output line about changing source lines of log 
my $change_file_color = 'bold green'; 
my $current_color = 'reset';

my $json = JSON->new->allow_nonref(0);

my $last_file = -1;
my $last_time = time;
my $prefix = '';

# it gets the name of log files from script parameters. you can specify as many files as you want 
my (@files) = @ARGV;
@files = @{get_config(qw(input files)) || []} unless @files;
#my @pos = map -s || 0, @files; # memorize files end position at the current eof
my @pos = map {0} @files; # memorize files end position at the current eof

# for each of file it puts prefix in the beggining of the line so it is quickly identifiable which log file was the source of that particular line
my @file_prefix = qw(< > 3: 4: 5: 6: 7:);
printf STDERR "Collect joined logging from:\t\t%s\n", join(", ", map "$files[$_]($file_prefix[$_])", 0..$#files);

# output file additional to terminal (stdout)
my $joined_name = 'joined.log';
print STDERR "Output joined log to:\t\t\t$joined_name\n";

# it outputs joined log to $joined_name as well as colored joined output to terminal (see level_color)
unlink $joined_name;
my $joined;

# output fields
my @out_fields = (
	{name => 'msg',		size	=> 	-80	}, 
	{name => 'level',	filter	=>	sub {"level=$_"}}, 
	{name => 'file',	filter 	=> 	sub {s{.*/odex/}{}}},
);

# which records to include in joined log
sub include { 
	my $rec = shift;
	1; # include all so far
}

# which records to exclude from joined log
sub exclude {
	my $rec = shift;
	return ($rec->{level} || '') eq 'trace';
}

# continue until ctrl-break
while (1) {
	usleep($wait_iteration);
    # try to read records beyond pos
	for my $i (0..$#files) {
		usleep($wait_file); 
		my $file = $files[$i];
		my $size = -s $file || 0;
		next unless $size > ($pos[$i]||0)+1;
		# we found the size of file is beyond last pos of the file
		$pos[$i] = show_records($i) || (-s $file);
	}
	close($joined) if $joined;
	undef $joined;
}

# show_record decides whether to show record and if not, returns before the last line
# last line outputs msg with %80s pad and then file and line where this msg was logged
# 

# filter out/ filter in record. 
# returns the current position on file

sub show_record {
	my ($i) = @_;
	# try to parse it with json 
	my $rec = eval {$json->decode($_)};
	if ($@) {
		# try to parse it with name="value" or name=value format
		my %rec = (m{(\S+)=(\S+)}g, m{(\S+)="(.*?[^\\])"}g);
		return unless keys %rec; # neither format worked
		$rec = \%rec;
	}
	my $level = $rec->{level};
	return unless (include($rec));
	return if exclude($rec);
	my @out;
	for my $field (@out_fields) {
		my $name = $field->{name};
		# value of the field
		local $_ = $rec->{$name};
		# apply filter
		my $filter = $level_color->{filter};
		$filter->() if $filter;
		# apply size
		my $size = $field->{size};
		$_ = sprintf("%${size}s", $_) if $size;
		push @out, $_;
	}
	unless (@out) {
		warn "no field to output: $_";
		return;
	}
	# if last_file changed, show new label along with time elapsed since last time file changed
	if ($last_file != $i) {
		$last_file = $i;
		my $elapsed = (time - $last_time) * 1000; # milliseconds
		$last_time = time;
		my $file = $files[$i];
		$prefix = $file_prefix[$i];
		# shows time elapsed since last file label has been printed and new file label
		local $_= sprintf("=== %5d ms %s %s\n", $elapsed, $file, show_time());
		output_line($change_file_color);
	}
    $_ = join("\t", @out)."\n";
	output_line($level_color->{$level},$prefix); # it outputs $_
	return;
}

# show_records shows records one at the time from $last pos until eof
sub show_records {
	my ($i) = @_;
	my $file = $files[$i];
	my $last_pos = $pos[$i];
	# read one line	
	open my $fh, "<", $file;
	seek $fh, $last_pos, 0;
	while (<$fh>) { show_record($i) }
	return tell $fh;
}

# outputs $_ with specified color in terminal and makes copy to $joined file
sub output_line {
	my $color = shift || 'reset';
	my $prefix = shift || '';
	print color($color) unless $color eq $current_color;
	$current_color = $color;
    print $prefix.$_; # terminal
	unless ($joined) {
		open $joined, ">>", $joined_name || die "can't open $joined_name for output";
	}
	print $joined $prefix.$_; # file
}

sub show_time {
	my ($sec,$min,$hour,$mday,$mon,$year,$wday,$yday,$isdst) = localtime(time);
	my ($seconds, $microseconds) = gettimeofday;
	$year = substr($year+1900,-2);
	return sprintf("%s-%02d-%02d %02d:%02d:%02d.%03d", $year, $mon+1, $mday, $hour, $min, $sec, $microseconds/1000);
}