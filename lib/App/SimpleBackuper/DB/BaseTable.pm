package App::SimpleBackuper::DB::BaseTable;

use strict;
use warnings FATAL => qw( all );
use Carp;
use Data::Dumper;

sub new { bless [] => shift }

sub find_row {
	my $self = shift;
	my($from, $to) = $self->_find(@_);
	die "Found more then one" if $to > $from;
	return undef if $from > $to;
	return $self->unpack( $self->[ $from ] );
}

sub find_all {
	my($self) = shift;
	my($from, $to) = $self->_find(@_);
	#warn "$self->_find(@_): from=$from, to=$to";
	#warn "self=[@$self]";
	my @result = map { $self->unpack( $self->[ $_ ] ) } $from .. $to;
	return \@result;
}

=pod Бинарный поиск.
Параметры:
	 0	- hashref с полями, которые должны быть таковыми в искомых записях.
	 	Упакованная запись должна начинаться с этих полей.
		Все поля должны быть фиксированной ширины, когда упакованы.
Результат:
	[0]	- индекс начала диапазона совпадений;
	[1]	- индекс конца диапазона совпадений;
	Для пустого массива результат всегда будет 0, -1.
	Для массива без искомого значения результат будет таким, что:
		- по индексу начала диапазона совпадений значение будет не искомое
		- по индексу начала диапазона совпадений можно вставить искомое значение и сортированность массива не нарушится
		- по индексу конца диапазона совпадений находятся те элементы, которые будут после вставленных новых элементов с искомым значением.
=cut
sub _find {
	my($self, $data) = @_;
	
	return 0, -1 if ! @$self;
	
	$data = $self->pack($data) if ref($data);
	
	# TODO: Находим бинарным поиском такой индекс в массиве от 0 до конца, что слева от него либо выход за границу массива, либо значение меньше искомого, а по самому этому индексу либо выход за границу массива, либо искомое значение, либо значение больше искомого. Это первая часть ответа
	
	my($from, $to, $min_from, $min_to, $max_from, $max_to) = (undef, undef, 0, 0, $#$self, $#$self);
	#my($status);
	while(! defined $from or ! defined $to) {
		
		my $mid_from = int($min_from + ($max_from - $min_from) / 2);
		my $mid_to = int($min_to + ($max_to - $min_to) / 2);
		
		#my $prev_status = $status || '';
		#$status = sprintf "%s (%d..%d..%d) .. %s (%d..%d..%d)\n",
		#	$from // '?', $min_from, $mid_from, $max_from,
		#	$to // '?', $min_to, $mid_to, $max_to;
		#print STDERR $status;
		#die "Endless cycle" if $status eq $prev_status;
		
		my $cmp;
		if(! defined $from) {
			#print "self=[@$self]\n";
			#print "defined \$self->[ $mid_from ] = ".defined($self->[ $mid_from ])."\n";
			$cmp = $data cmp substr( $self->[ $mid_from ], 0, length($data) );
			#printf STDERR "data %s mid_from, ", {-1 => '<', 0 => '=', +1 => '>'}->{$cmp};
			if($cmp == -1) {			# data < mid_from
				if($mid_from == 0) {
					#print STDERR "\n";
					return 0, -1;
				} else {
					$cmp = $data cmp substr( $self->[ $mid_from - 1 ], 0, length($data) );
					#printf STDERR "data %s mid_from-1, ", {-1 => '<', 0 => '=', +1 => '>'}->{$cmp};
					if($cmp == -1) {	# data < mid_from-1
						$max_from = $mid_from - 1;
						#print STDERR '$max_from = $mid_from - 1';
						#print STDERR "\n";
						return 0, -1 if $max_from < 0;
					}
					elsif($cmp == 1) {	# data > mid_from-1
						#print STDERR "\n";
						return $mid_from, $mid_from - 1;
					}
					else {				# data = mid_from-1
						$max_from = $to = $mid_from - 1;
						#print STDERR '$max_from = $to = $mid_from - 1';
					}
				}
			}
			elsif($cmp == 1) {			# data > mid_from
				$min_from = $mid_from + 1;
				#print STDERR '$min_from = $mid_from + 1';
				#print STDERR "\n";
				return $#$self + 1, $#$self if $min_from > $#$self;
			}
			else {						# data = mid_from
				if($mid_from == 0) {
					$from = 0;
					#print STDERR '$from = 0';
				} else {
					$cmp = $data cmp substr( $self->[ $mid_from - 1 ], 0, length($data) );
					#printf STDERR "data %s mid_from-1, ", {-1 => '<', 0 => '=', +1 => '>'}->{$cmp};
					if($cmp == -1) {	# data < mid_from-1
						die "Array is not sorted: item #".($mid_from - 1)." > item #$mid_from ($self->[$mid_from-1] > $self->[$mid_from])";
					}
					elsif($cmp == 1) {	# data > mid_from-1
						$from = $mid_from;
						#print STDERR '$from = $mid_from';
					}
					else {				# data = mid_from-1
						$max_from = $mid_from - 1;
						#print '$max_from = $mid_from - 1';
						#print STDERR "\n";
						return 0, -1 if $max_from < 0;
					}
				}
			}
			#print STDERR "\n";
		}
		
		if(! defined $to) {
			$cmp = $data cmp substr( $self->[ $mid_to ], 0, length($data) );
			#printf STDERR "data %s mid_to, ", {-1 => '<', 0 => '=', +1 => '>'}->{$cmp};
			if($cmp == 1) {				# data > mid_to
				if($mid_to == $#$self) {
					#print STDERR "\n";
					return $#$self + 1, $#$self;
				} else {
					$cmp = $data cmp substr( $self->[ $mid_to + 1 ], 0, length($data) );
					#printf STDERR "data %s mid_to+1, ", {-1 => '<', 0 => '=', +1 => '>'}->{$cmp};
					if($cmp == 1) {		# data > mid_to+1
						$min_to = $mid_to + 2;
						#print STDERR '$min_to = $mid_to + 2';
						#print STDERR "\n";
						return $#$self + 1, $#$self if $min_to > $#$self;
					}
					elsif($cmp == -1) {	# data < mid_to+1
						#print STDERR "\n";
						return $mid_to + 1, $mid_to;
					}
					else {				# data = mid_to+1
						$min_to = $from = $mid_to + 1;
						#print STDERR '$min_to = $from = $mid_to + 1';
					}
				}
			}
			elsif($cmp == -1) {			# data < mid_to
				$max_to = $mid_to;
				#print STDERR '$max_to = $mid_to';
			}
			else {						# data = mid_to
				if($mid_to == $#$self) {
					$to = $#$self;
					#print STDERR '$to = $#$self';
				} else {
					$cmp = $data cmp substr( $self->[ $mid_to + 1 ], 0, length($data) );
					#printf STDERR "data %s mid_to+1, ", {-1 => '<', 0 => '=', +1 => '>'}->{$cmp};
					if($cmp == -1) {	# data < mid_to+1
						$to = $mid_to;
						#print STDERR '$to = $mid_to';
					}
					elsif($cmp == 1) {	# data > mid_to+1
						die "Array is not sorted: item #$mid_to > item #".($mid_to + 1)." ($self->[$mid_to] > $self->[$mid_to+1])";
					}
					else {				# data = mid_to+1
						$min_to = $mid_to + 1;
						#print STDERR '$min_to = $mid_to + 1';
					}
				}
			}
			#print STDERR "\n";
		}
		
	}
	
	return $from, $to;
}

sub upsert {
	my($self, $search_row, $data) = @_;
	
	$_ = $self->pack( $_ ) foreach grep { ref $_ } $search_row, $data;
	
	my($from, $to) = $self->_find( $search_row );
	
	if($to < $from) {
		splice( @$self, $from, 0, $data );
	} else {
		die "Found more then 1 row, can't update" if $to > $from;
		$self->[ $from ] = $data;
	}
	
	return $self;
}

sub delete {
	my($self, $row) = @_;
	
	my($from, $to) = $self->_find($row);
	confess "Value ".Data::Dumper->new($row)->Indent(0)->Terse(1)->Pair('=>')->Quotekeys(0)->Sortkeys(1)->Dump()." wasn't found in $self" if $to < $from;
	splice(@$self, $from, $to - $from + 1);
	
	return $self;
}

use App::SimpleBackuper::DB::Packer;
sub packer { shift; App::SimpleBackuper::DB::Packer->new( @_ ) }

1;
