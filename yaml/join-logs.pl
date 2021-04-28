#!/usr/bin/perl
use strict;
use warnings;
use JSON; # it expects logs to be written in JSON format 
use Time::HiRes qw(time usleep gettimeofday);
use Data::Dumper;
use Term::ANSIColor;
use YAML::Tiny;

# config file is either argument of the script with the extension .yaml or name of the script minus .pl plus .yaml
local $_ = $0;
s/\.pl$//;
my ($config_file) = grep m{\.yaml} && -f, @ARGV, "$_.yaml";
die "don't know what output without config file!" unless -f $config_file;
print STDERR "reading config file from:\t\t$config_file\n", ;
my $config = YAML::Tiny::->read( $config_file )->[0] || {};
#die Dumper($config);

# interval in microseconds (10e-6 - one milllions of second)
my $wait_file = get_config(qw(wait file)) || 10_000; # wait 0.01s before checking next file
my $wait_iteration = get_config(qw(wait iteration)) || 100_000; # wait 0.1s before next iteration over files

# outputs to terminal lines with corresponsding level in custom colors. default - reset
my $level_color = get_config(qw(color level)) || {}; #'error' => 'bold red', 'trace' => 'yellow', 'info'=>'blue'}; 
# color to output line about changing source lines of log 
my $change_file_color = get_config(qw(color change_file)) || 'bold green'; 
my $current_color = 'reset';

# build check_conditions subs for include & exclude patterns
my $include = build_check_conditions($config->{include},1);
my $exclude = build_check_conditions($config->{exclude},0);

my $json = JSON->new->allow_nonref(0);

# this script watches indefinitely log files and joins record from them and outputs joined record in format nicely suited for debugging
# this easy approach setups sender and receiver to output files in the current directory with those simple names.
my (@files) = grep $_ ne $config_file, @ARGV;
@files = @{get_config(qw(input files)) || []} unless @files;
printf STDERR "Collect joined logging from:\t\t%s\n", join(", ", @files);

# output file additional to terminal (stdout)
my $joined_name = get_config(qw(output file)) || 'joined.log';
print STDERR "Output joined log to:\t\t\t$joined_name\n";

# it outputs joined log to $joined_name as well as colored joined output to terminal (see level_color)
unlink $joined_name;
my $joined;

# output fields
my $out_fields = $config->{output}{fields};


my @tag = map m{.*/(.*?)\..*}; # strips filename from path and extension
my @pos = map -s || 0, @files; # memorize files end position 

my $last_file = '';
my $last_time = time;

# continue until ctrl-break
while (1) {
	usleep($wait_iteration);
    # try to read records behind pos
	for my $i (0..$#files) {
		usleep($wait_file); 
		my $file = $files[$i];
		my $size = -s $file || 0;
		next unless $size > $pos[$i]+1;
		$pos[$i] = show_records($file, $pos[$i]);
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
	my ($file,$last_pos) = @_;
	# try to parse it with json
	my $rec = eval {$json->decode($_)};
	if ($@) {
		#print "$file:$last_pos: JSON error $@\n"; # debug
		# ignore any line if parser fails
		return;
	}
	my $level = $rec->{level};
	unless ($include->($rec)) {
		#print "$file:$last_pos: not included\n"; # debug
		return;
	}
	if (my $field_cond = $exclude->($rec)) {
		#print "$file:$last_pos: excluded: $field_cond\n"; # debug
		return;
	}
	#print "$file:$last_pos: create output\n"; # debug
	my @out;
	for (@$out_fields) {
		$_ = {$_=>{}} unless ref($_) eq 'HASH';
		my ($name) = keys %$_;
		my ($params) = $_->{$name};
		# value of the field
		local $_ = $rec->{$name};
		# apply filter
		my $filter = $params->{filter};
		eval $filter if $filter;
		# apply size
		my $size = $params->{size};
		$_ = sprintf("%${size}s", $_) if $size;
		push @out, $_;
	}
	die "no field to output!" unless @out;
	# if last_file changed, show new label along with time elapsed since last time file changed
	if ($last_file ne $file) {
		$last_file = $file;
		my $elapsed = (time - $last_time) * 1000; # milliseconds
		$last_time = time;
		# shows time elapsed since last file label has been printed and new file label
		local $_= sprintf("=== %5d ms %s %s\n", $elapsed, $file, show_time());
		output_line($change_file_color);
	}
    $_ = join("\t", @out)."\n";
	output_line($level_color->{$level}); # it outputs $_
	return;
}

# show_records shows records one at the time from $last pos until eof
sub show_records {
	my ($file,$last_pos) = @_;
	# read one line	
	open my $fh, "<", $file;
	seek $fh, $last_pos, 0;
	while (<$fh>) { show_record($file,$last_pos) }
	return tell $fh;
}

# outputs $_ with specified color in terminal and makes copy to $joined file
sub output_line {
	my $color = shift || 'reset';
	print color($color) unless $color eq $current_color;
	$current_color = $color;
    print $_; # terminal
	unless ($joined) {
		open $joined, ">>", $joined_name || die "can't open $joined_name for output";
	}
	print $joined $_; # file
}

# build_check_conditions builds subroutine which checks whether current line is to be included/excluded to output
# $conditions contains include/exclude conditions for each field.
# $no_conditions = 1 for include and 0 for exclude (that means if sub will return true if there is no any conditions for include and false for exclude)
sub build_check_conditions {
	my ($conditions,$no_conditions) = @_;
	return sub { $no_conditions } unless $conditions;
	my @fields = keys %$conditions;
	# unify type of $conditions
	for my $field (@fields) {
		my $checks = $conditions->{$field };
		$checks = [$checks] unless ref($checks);
		for (@$checks) {
			my $condition = $_;
			$_ = eval "sub {return $_?qq{$field}:0;}";
			die "failed to compile condition $condition for field $field : $@" if $@;
		}			
		$conditions->{$field} = $checks
	}
	return sub {
		my $rec = shift;
		for my $field (@fields) {
			local $_ = $rec->{$field}; # value of filed
			my $conditions = $conditions->{$field};
			for my $condition (@$conditions) {
				# check value of field against the condition
				return "$field:$_" if $condition->();
			}
		}
		0; # no condition has been met
	}
}

# get_config returns value of nested key, 
# e.g. get_config(qw(f1 f2 f3)) equal to $config->{f1}{f2}{f3}
# it returns undef if nested key does not exist
sub get_config {
	my @fields = @_;
	my $result = $config;
	for (@_) {
		return unless ref($result) eq 'HASH';
		$result = $result->{$_};
	}
	return $result;
}

sub show_time {
	my ($sec,$min,$hour,$mday,$mon,$year,$wday,$yday,$isdst) = localtime(time);
	my ($seconds, $microseconds) = gettimeofday;
	$year = substr($year+1900,-2);
	return sprintf("%s-%02d-%02d %02d:%02d:%02d.%03d", $year, $mon+1, $mday, $hour, $min, $sec, $microseconds/1000);
}