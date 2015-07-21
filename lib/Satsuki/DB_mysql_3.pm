use strict;
#------------------------------------------------------------------------------
# Split from Satsuki::DB_mysql.pm for AUTOLOAD.
#------------------------------------------------------------------------------
package Satsuki::DB_mysql;
use Satsuki::DB_mysql ();
use Satsuki::DB_mysql_2 ();
use Satsuki::DB_share_3;
###############################################################################
# ■テーブルの操作
###############################################################################
#------------------------------------------------------------------------------
# ●create table
#------------------------------------------------------------------------------
sub create_table {
	my ($self, $table, $colums) = @_;
	my $dbh  = $self->{dbh};
	my $ROBJ = $self->{ROBJ};
	$table =~ s/\W//g;
	if ($table eq '') {  $self->error('Called create_table() with null table name.'); return 9; }

	# テーブル構造の解析
	my $cols;
	my @index_columns;
	my %col_is_text;
	my $varchar_size = $self->{index_text_max_length};
	foreach(@$colums) {
		my $check;
		my $col = $_->{name};
		$col =~ s/\W//g;		# check 制約は mysql に実装されていない（無視されるのみ）
		if    ($_->{type} eq 'int')   { $cols .= ", $col INT"; }
		elsif ($_->{type} eq 'float') { $cols .= ", $col FLOAT"; }
		elsif ($_->{type} eq 'flag')  { $cols .= ", $col BOOLEAN"; $check=" CHECK($col=0 OR $col=1)"; }
		elsif ($_->{type} eq 'text')  {
			if ($_->{unique})     { $cols .= ", $col VARCHAR(" . int($self->{unique_text_size} || 256) .")"; }
		          else                { $cols .= ", $col TEXT"; $col_is_text{$col}=1; }
		}
		elsif ($_->{type} eq 'ltext') { $cols .= ", $col MEDIUMTEXT"; }
		else {
			$self->error('Column "%s" have invalid type "%s" in "CREATE TABLE %s"', $col, $_->{type}, $table);
			return 20;
		}
		if ($_->{index})    { push(@index_columns, $col); }
		if ($_->{unique})   { $cols .= ' UNIQUE';   }	# ユニーク制約
		if ($_->{not_null}) { $cols .= ' NOT NULL';
			# NOT NULL制約時は generate_pkey のために適当なデフォルト値を設定する
			if ($_->{type} eq 'int' || $_->{type} eq 'float' || $_->{type} eq 'flag') {
				$cols .= ' DEFAULT 0';
			} else {
				$cols .= " DEFAULT ''";
			}
		 }
		$cols .= $check;
		if ($_->{ref_pkey}) {	# 外部キー制約（ table_name.col_name 形式の文字列 ）
			my $ref_pkey = $_->{ref_pkey};	# mysql標準では無効
			$ref_pkey =~ s/[^\w\.]//g;
			my ($ref_table, $ref_col) = split(/\./, $ref_pkey);
			$cols .= " REFERENCES $ref_table($ref_col)";
		}
	}
	# テーブル作成
	my $sql = "CREATE TABLE $table(pkey SERIAL PRIMARY KEY$cols)";
	if ($self->{engine}) {	# DBエンジン選択
		$self->{engine} =~ s/\W//g;
		$sql .= " ENGINE=" . $self->{engine};
	}
	my $sth = $dbh->prepare($sql);
	$self->debug($sql);	# debug-safe
	$sth && $sth->execute();
	if (!$sth || $dbh->err) {
		$self->error($sql);
		$self->error($dbh->errstr);
		return 1;
	}

	# INDEX 作成
	#	CREATE INDEX table_colname_idx ON table (colname);
	foreach(@index_columns) {
		my $length=''; if ($col_is_text{$_}) { $length="(". int($self->{text_index_size}) .")"; }
		my $sql = "CREATE INDEX ${table}_${_}_idx ON $table($_$length)";
		$dbh->do($sql);
		$self->debug($sql);	# debug-safe
		if ($dbh->err) {
			$self->error($sql);
			$self->error($dbh->errstr);
			return 2;
		}
	}

	return 0;
}
#------------------------------------------------------------------------------
# ●テーブルの削除
#------------------------------------------------------------------------------
# 成功時は 0 が返る
sub drop_table {
	my ($self, $table) = @_;
	my $dbh  = $self->{dbh};
	my $ROBJ = $self->{ROBJ};
	$table =~ s/\W//g;

	my $sql = "DROP TABLE $table";
	$dbh->do($sql);
	if ($dbh->err) {
		$self->error($sql);
		$self->error($dbh->errstr);
		return 1;
	}

	# テーブルの存在キャッシュを削除
	my $cache    = $self->{exist_tables_cache};
	my $cache_id = $self->{db_id} . $table;
	delete $cache->{$cache_id};

	return 0;
}

###############################################################################
# ■オプショナル関数
###############################################################################
#------------------------------------------------------------------------------
# ●カラムの追加
#------------------------------------------------------------------------------
sub add_column {
	my ($self, $table, $h) = @_;
	my $dbh  = $self->{dbh};
	my $ROBJ = $self->{ROBJ};

	$table =~ s/\W//g;
	if ($table eq '') { return 9; }

	# カラム情報の解析
	my $col = $h->{name};
	$col =~ s/\W//g;
	my ($sql, $col_is_text, $check);
	if    ($h->{type} eq 'int')   { $sql .= "$col INT";   }
	elsif ($h->{type} eq 'float') { $sql .= "$col FLOAT"; }
	elsif ($h->{type} eq 'flag')  { $sql .= "$col TINYINT UNSIGNED"; $check=" CHECK($col=0 OR $col=1)"; }
	elsif ($h->{type} eq 'text')  {
		if ($_->{unique})     { $sql .= "$col VARCHAR(" . int($self->{unique_text_size} || 256) .")"; }
	          else                { $sql .= "$col TEXT"; $col_is_text=1; }
	}
	elsif ($h->{type} eq 'ltext') { $sql .= "$col MEDIUMTEXT"; }
	else {
		$self->error('Column "%s" have invalid type "%s"', $col, $h->{type});
		return 20;
	}
	if ($h->{unique})   { $sql .= ' UNIQUE';   }	# ユニーク制約
	if ($h->{not_null}) { $sql .= ' NOT NULL'; }	# NOT NULL制約
	$sql .= $check;
	if ($h->{ref_pkey}) {	# 外部キー制約（ table_name.col_name 形式の文字列 ）
		my $ref_pkey = $h->{ref_pkey};	# mysql標準では無効
		$ref_pkey =~ s/[^\w\.]//g;
		my ($ref_table, $ref_col) = split(/\./, $ref_pkey);
		$sql .= " REFERENCES $ref_table($ref_col)";
	}

	# SQL発行
	$sql = "ALTER TABLE $table ADD COLUMN $sql";
	my $sth = $dbh->prepare($sql);
	$self->debug($sql);	# debug-safe
	$sth && $sth->execute();
	if (!$sth || $dbh->err) {
		$self->error($sql);
		$self->error($dbh->errstr);
		return 1;
	}

	# INDEX 作成
	#	CREATE INDEX table_colname_idx ON table (colname);
	if ($h->{index}) {
		my $length=''; if ($col_is_text) { $length="(". int($self->{text_index_size}) .")"; }
		my $sql = "CREATE INDEX ${table}_${col}_idx ON $table($col$length)";
		$dbh->do($sql);
		$self->debug($sql);	# debug-safe
		if ($dbh->err) {
			$self->error($sql);
			$self->error($dbh->errstr);
			return 2;
		}
	}
	return 0;
}

#------------------------------------------------------------------------------
# ●カラムの削除
#------------------------------------------------------------------------------
sub drop_column {
	my ($self, $table, $column) = @_;
	my $dbh  = $self->{dbh};
	my $ROBJ = $self->{ROBJ};
	$table  =~ s/\W//g;
	$column =~ s/\W//g;
	if ($table eq '' || $column eq '') { return 9; }

	# SQL発行
	my $sql = "ALTER TABLE $table DROP COLUMN $column";
	my $sth = $dbh->prepare($sql);
	$self->debug($sql);	# debug-safe
	$sth && $sth->execute();
	if (!$sth || $dbh->err) {
		$self->error($sql);
		$self->error($dbh->errstr);
		return 1;
	}

	return 0;
}

#------------------------------------------------------------------------------
# ●indexの追加
#------------------------------------------------------------------------------
sub add_index {
	my ($self, $table, $column) = @_;
	my $dbh  = $self->{dbh};
	my $ROBJ = $self->{ROBJ};
	$table  =~ s/\W//g;
	$column =~ s/\W//g;
	if ($table eq '' || $column eq '') { return 9; }

	# カラム情報の解析
	my $sql = "CREATE INDEX ${table}_${column}_idx ON $table($column)";
	my $sth = $dbh->prepare($sql);
	$self->debug($sql);	# debug-safe
	$sth && $sth->execute();
	if (!$sth || $dbh->err) {
		$self->error($sql);
		$self->error($dbh->errstr);
		return 1;
	}

	return 0;
}

###############################################################################
# ■SQL直接指定関数
###############################################################################
#------------------------------------------------------------------------------
# ●[SQL] create table
#------------------------------------------------------------------------------
sub sql_create_table {
	my $self = shift;
	my ($table, $sql, $ary) = @_;
	my $dbh  = $self->{dbh};
	my $ROBJ = $self->{ROBJ};

	# テーブル作成
	my $sth = $dbh->prepare($sql);
	$self->debug($sql);	# debug-safe
	$sth && $sth->execute(@{$ary || []});
	if (!$sth || $dbh->err) {
		$self->error($sql);
		$self->error($dbh->errstr);
		return 1;
	}

	return 0;
}

###############################################################################
# ●タイマーの仕込み
###############################################################################
&embed_timer_wrapper(__PACKAGE__);

1;
