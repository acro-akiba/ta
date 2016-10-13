package Text::TogoAnnotator;

# Yasunori Yamamoto / Database Center for Life Science
# -- 変更履歴 --
# * 2013.11.28 辞書ファイル仕様変更による。
# 市川さん>宮澤さんの後任が記載するルールを変えたので、正解データとしてngram掛けるのは、第3タブが○になっているもの、だけではなく、「delとRNA以外」としてください。
# * 2013.12.19 前後の"の有無の他に、出典を示す[nite]的な文字の後に"があるものと前に"があるものがあって全てに対応していなかったことに対応。
# * 2014.06.12 モジュール化
# getScore関数内で//オペレーターを使用しているため、Perlバージョンが5.10以降である必要がある。
# * 2014.09.19 14/7/23 リクエストに対応
# 1. 既に正解辞書に完全一致するエントリーがある場合は、そのままにする。
# 2. "subunit", "domain protein", "family protein" などがあり、辞書中にエントリーが無い場合は、そのままにする。
# * 2014.11.6
# 「辞書で"del"が付いているものは、人の目で確認することが望ましいという意味です。」とのコメントを受け、出力で明示するようにした。
# 具体的には、result:$query, match:"del", info:"Human check preferable" が返る。
# ハイフンの有無だけでなく空白の有無も問題を生じさせうるので、全ての空白を取り除く処理を加えてみた。
# * 2014.11.7
# Bag::Similarity::Cosineモジュールの利用で実際のcosine距離を取得してみる。
# なお、simstringには距離を取得する機能はない。
# n-gramの値はsimstringと同じ値を適用。
# "fragment"をavoid_cs_termsに追加。
# * 2014.11.21
# スコアの並び替えについては、クエリ中の語が含まれる候補を優先し、続いてcosine距離を考慮する方針に変更。
# * 2016.3.16
# exもしくはcsの際の結果のみを配列に含むresult_arrayを追加。
# * 2016.5.10
# 辞書にg列（curated）とh列（note）があることを想定した修正。
# 辞書ファイルの名前が.gzで終る場合は、gzip圧縮されたファイルとして扱い、展開する仕様に変更。
# * 2016.7.8
# Before -> After、After -> Curated ではなく、Curated辞書の書き換え前エントリをTogoAnnotator辞書のBeforeに含めて、それを優先されるようにする（完全一致のみ）。
# https://bitbucket.org/yayamamo/togoannotator/issues/3/curated
# なお、マッチさせるときには大文字小文字の違いを無視する。
# * 2016.10.13
# 酵素名辞書とマッチするデフィニションは優先順位を高めるようにした。
# 英語表記を米語表記に変換するようにした。

use warnings;
use strict;
use Fatal qw/open/;
use File::Path 'mkpath';
use Bag::Similarity::Cosine;
use String::Trim;
use simstring;
use DB_File;
use PerlIO::gzip;
use Lingua::EN::ABC qw/b2a/;
use utf8;

my ($sysroot, $niteAll, $curatedDict, $enzymeDict);
my ($nitealldb_d_name, $nitealldb_e_name);
my ($niteall_d_cs_db, $niteall_e_cs_db);
my ($cos_threshold, $e_threashold, $cs_max, $n_gram, $cosine_object, $ignore_chars);

my (
    @sp_words, # マッチ対象から外すが、マッチ処理後は元に戻して結果に表示させる語群。
    @avoid_cs_terms # コサイン距離を用いた類似マッチの対象にはしない文字列群。種々の辞書に完全一致しない場合はno_hitとする。
    );
my (
    %correct_definitions, # マッチ用内部辞書には全エントリが小文字化されて入るが、同じく小文字化したクエリが完全一致した場合には辞書に既にあるとして処理する。
    %histogram,
    %convtable,           # 書換辞書の書換前後の対応表。小文字化したクエリが、同じく小文字化した書換え前の語に一致した場合は対応する書換後の語を一致させて出力する。
    %negative_min_words,  # コサイン距離を用いた類似マッチではクエリと辞書中のエントリで文字列としては類似していても、両者の間に共通に出現する語が無い場合がある。
    # その場合、共通に出現する語がある辞書中エントリを優先させる処理をしているが、本処理が逆効果となってしまう語がここに含まれる。
    %wospconvtableD, %wospconvtableE, # 全空白文字除去前後の対応表。書換え前と後用それぞれ。
    %name_provenance,     # 変換後デフィニションの由来。
    %curatedHash,         # curated辞書のエントリ（キーは小文字化する）
    %enzymeHash           # 酵素辞書のエントリ（小文字化する）
    );
my ($minfreq, $minword, $ifhit, $cosdist);

sub init {
    my $_this = shift;
    $cos_threshold = shift; # cosine距離で類似度を測る際に用いる閾値。この値以上類似している場合は変換対象の候補とする。
    $e_threashold  = shift; # E列での表現から候補を探す場合、辞書中での最大出現頻度がここで指定する数未満の場合のもののみを対象とする。
    $cs_max        = shift; # 複数表示する候補が在る場合の最大表示数
    $n_gram        = shift; # N-gram
    $sysroot       = shift; # 辞書や作業用ファイルを生成するディレクトリ
    $niteAll       = shift; # 辞書名
    $curatedDict   = shift; # curated辞書名（形式は同一）

    $enzymeDict = "enzyme/enzyme_names.txt";

    @sp_words = qw/putative probable possible/;
    @avoid_cs_terms = (
	"subunit",
	"domain protein",
	"family protein",
	"-like protein",
	"fragment",
	);
    for ( @avoid_cs_terms ){
	s/[^\w\s]//g;
	do {$negative_min_words{$_} = 1} for split " ";
    }

    # 未定議の場合の初期値
    $cos_threshold //= 0.6;
    $e_threashold //= 30;
    $cs_max //= 5;
    $n_gram //= 3;
    $ignore_chars = qr{[-/,:+()]};

    $cosine_object = Bag::Similarity::Cosine->new;

    readDict();
}

=head
類似度計算用辞書およびマッチ（完全一致）用辞書の構築
  類似度計算は simstring
    類似度計算用辞書の見出し語は全て空白文字を除去し、小文字化したもの
    書換前後の語群それぞれを独立した辞書にしている
  完全一致はハッシュ
    ハッシュは書換用辞書とキュレーテッド
    更に書換用辞書についてはconvtableとcorrect_definition
    convtableのキーは書換前の語に対して特殊文字を除去し、小文字化したもの
    convtableの値は書換後の語
    correct_definitionのキーは書換後の語に対して特殊文字を除去し、小文字化したもの
    correct_definitionの値は書換後の語
=cut

sub readDict {
    # 類似度計算用辞書構築の準備
    my $dictdir = 'dictionary/cdb_nite_ALL';

    if (!-d  $sysroot.'/'.$dictdir){
	mkpath($sysroot.'/'.$dictdir);
    }

    for my $f ( <${sysroot}/${dictdir}/[de]*> ){
	unlink $f;
    }

    $nitealldb_d_name = $sysroot.'/'.$dictdir.'/d'; # After
    $nitealldb_e_name = $sysroot.'/'.$dictdir.'/e'; # Before

    my $niteall_d_db = simstring::writer->new($nitealldb_d_name, $n_gram);
    my $niteall_e_db = simstring::writer->new($nitealldb_e_name, $n_gram);

    # キュレーテッド辞書の構築
    if($curatedDict){
	open(my $curated_dict, $sysroot.'/'.$curatedDict);
	while(<$curated_dict>){
	    chomp;
	    my (undef, undef, undef, undef, $name, undef, $curated, $note) = split /\t/;
	    $name //= "";
	    trim( $name );
	    trim( $curated );
	    $name =~ s/^"\s*//;
	    $name =~ s/\s*"$//;
	    $curated =~ s/^"\s*//;
	    $curated =~ s/\s*"$//;

	    if($curated){
		$curatedHash{lc($name)} = $curated;
	    }
	}
	close($curated_dict);
    }

    # 酵素辞書の構築
    open(my $enzyme_dict, $sysroot.'/'.$enzymeDict);
    while(<$enzyme_dict>){
    	chomp;
    	trim( $_ );
    	$enzymeHash{lc($_)} = $_;
    }
    close($enzyme_dict);

    # 類似度計算用および変換用辞書の構築
    my $total = 0;
    my $nite_all;
    if($niteAll =~ /\.gz$/){
	open($nite_all, "<:gzip", $sysroot.'/'.$niteAll);
    }else{
	open($nite_all, $sysroot.'/'.$niteAll);
    }
    while(<$nite_all>){
	chomp;
	my (undef, $sno, $chk, undef, $name, $b4name, undef) = split /\t/;
	next if $chk eq 'RNA' or $chk eq 'OK';
	# next if $chk eq 'RNA' or $chk eq 'del' or $chk eq 'OK';

	$name //= "";   # $chk が "del" のときは $name が空。
	trim( $name );
	trim( $b4name );
	$name =~ s/^"\s*//;
	$name =~ s/\s*"$//;
	$b4name =~ s/^"\s*//;
	$b4name =~ s/\s*"$//;

	$name_provenance{$name} = "dictionary";
	if($curatedHash{lc($name)}){
	    my $_name = lc($name);
	    $name = $curatedHash{$_name};
	    $name_provenance{$name} = "curated (after)";
	    # print "#Curated (after): ", $_name, "->", $name, "\n";
	}else{
	    for ( @sp_words ){
		$name =~ s/^$_\s+//i;
	    }
	}

	my $lcb4name = lc($b4name);
	$lcb4name =~ s{$ignore_chars}{ }g;
	$lcb4name = trim($lcb4name);
	$lcb4name =~ s/  +/ /g;
	for ( @sp_words ){
	    if(index($lcb4name, $_) == 0){
		$lcb4name =~ s/^$_\s+//;
	    }
	}

	if($chk eq 'del'){
	    $convtable{$lcb4name}{'__DEL__'}++;
	}else{
	    $convtable{$lcb4name}{$name}++;

	    # $niteall_e_db->insert($lcb4name);
	    (my $wosplcb4name = $lcb4name) =~ s/ //g;   #### 全ての空白を取り除く
	    $niteall_e_db->insert($wosplcb4name);
	    $wospconvtableE{$wosplcb4name}{$lcb4name}++;

	    my $lcname = lc($name);
	    $lcname =~ s{$ignore_chars}{ }g;
	    $lcname = trim($lcname);
	    $lcname =~ s/  +/ /g;
	    next if $correct_definitions{$lcname};
	    $correct_definitions{$lcname} = $name;
	    for ( split " ", $lcname ){
		s/\W+$//;
		$histogram{$_}++;
		$total++;
	    }
	    #$niteall_d_db->insert($lcname);
	    (my $wosplcname = $lcname) =~ s/ //g;   #### 全ての空白を取り除く
	    $niteall_d_db->insert($wosplcname);
	    $wospconvtableD{$wosplcname}{$lcname}++;
	}
    }
    close($nite_all);

    $niteall_d_db->close;
    $niteall_e_db->close;
}

sub openDicts {
    $niteall_d_cs_db = simstring::reader->new($nitealldb_d_name);
    $niteall_d_cs_db->swig_measure_set($simstring::cosine);
    $niteall_d_cs_db->swig_threshold_set($cos_threshold);
    $niteall_e_cs_db = simstring::reader->new($nitealldb_e_name);
    $niteall_e_cs_db->swig_measure_set($simstring::cosine);
    $niteall_e_cs_db->swig_threshold_set($cos_threshold);
}

sub closeDicts {
    $niteall_d_cs_db->close;
    $niteall_e_cs_db->close;
}

sub retrieve {
    shift;
    ($minfreq, $minword, $ifhit, $cosdist) = undef;
    my $query = my $oq = shift;
    # $query ||= 'hypothetical protein';
    my $lc_query = $query = lc($query);
    $query =~ s{$ignore_chars}{ }g;
    $query =~ s/^"\s*//;
    $query =~ s/\s*"\s*$//;
    $query =~ s/\s+\[\w+\]$//;
    $query =~ s/\s*"$//;
    $query =~ s/  +/ /g;
    $query = trim($query);

    my $prfx = '';
    my ($match, $result, $info) = ('') x 3;
    my @results;
    for ( @sp_words ){
        if(index($query, $_) == 0){
            $query =~ s/^$_\s+//;
	    $prfx = $_. ' ';
	    last;
        }
    }
    if( $curatedHash{$lc_query} ){
        $match ='ex';
        $result = $curatedHash{$lc_query};
	$info = 'in_curated_dictionary (before): '. $query;
	$results[0] = $result;
    }elsif( $correct_definitions{$query} ){
	# print "\tex\t", $prfx. $correct_definitions{$query}, "\tin_dictionary: ", $query;
        $match ='ex';
        $result = $prfx. $correct_definitions{$query};
	$info = 'in_dictionary '. ($prfx?"(prefix=${prfx})":""). ': '. $query;
	$results[0] = $result;
    }elsif($convtable{$query}){
	# print "\tex\t", $prfx. $convtable{$query}, "\tconvert_from: ", $query;
	if($convtable{$query}{'__DEL__'}){
	    my @others = grep {$_ ne '__DEL__'} keys %{$convtable{$query}};
	    $match = 'del';
	    $result = $query;
	    $info = 'Human check preferable (other entries with the same "before" entry: '.join(" @@ ", @others).')';
	}else{
	    $match = 'ex';
	    $result = join(" @@ ", map {$prfx. $_} keys %{$convtable{$query}});
	    $info = 'convert_from dictionary ( prefix='. $prfx. '): '. $query;
	    $results[0] = $result;
	}
    }else{
	my $avoidcsFlag = 0;
	for ( @avoid_cs_terms ){
	    $avoidcsFlag = ($query =~ m,\b$_$,);
	    last if $avoidcsFlag;
	}

	#全ての空白を取り除く処理をした場合への対応
	#my $retr = $niteall_d_cs_db->retrieve($query);
	(my $qwosp = $query) =~ s/ //g;
	my $retr = $niteall_d_cs_db->retrieve($qwosp);
	#####
	my %qtms = map {$_ => 1} grep {s/\W+$//;$histogram{$_}} (split " ", $query);
	if($retr->[0]){
	    ($minfreq, $minword, $ifhit, $cosdist) = getScore($retr, \%qtms, 1, $qwosp);
	    my %cache;
	    #全ての空白を取り除く処理をした場合には検索結果の文字列を復元する必要があるため、下記部分をコメントアウトしている。
	    #my @out = sort {$minfreq->{$a} <=> $minfreq->{$b} || $a =~ y/ / / <=> $b =~ y/ / /} grep {$cache{$_}++; $cache{$_} == 1} @$retr;
	    #その代わり以下のコードが必要。
	    my @out = sort by_priority grep {$cache{$_}++; $cache{$_} == 1} map { keys %{$wospconvtableD{$_}} } @$retr;
	    #####
	    my $le = (@out > $cs_max)?($cs_max-1):$#out;
	    # print "\tcs\t", join(" @@ ", (map {$prfx.$correct_definitions{$_}.' ['.$minfreq->{$_}.':'.$minword->{$_}.']'} @out[0..$le]));
	    if($avoidcsFlag && $minfreq->{$out[0]} == -1 && $negative_min_words{$minword->{$out[0]}}){
		$match ='no_hit';
		$result = $oq;
		$info = 'cs_avoidance: '. $query;
	    }else{
		$match = 'cs';
		$result = $prfx.$correct_definitions{$out[0]};
		$info   = join(" @@ ", (map {$prfx.$correct_definitions{$_}.' ['.$minfreq->{$_}.':'.$minword->{$_}.']'} @out[0..$le]));
		@results = map { $prfx.$correct_definitions{$_} } @out[0..$le];
	    }
	}else{
	    #全ての空白を取り除く処理をした場合への対応
	    #my $retr_e = $niteall_e_cs_db->retrieve($query);
	    my $retr_e = $niteall_e_cs_db->retrieve($qwosp);
	    #####
	    if($retr_e->[0]){
		($minfreq, $minword, $ifhit, $cosdist) = getScore($retr_e, \%qtms, 0, $qwosp);
		my @hits = keys %$ifhit;
		my %cache;
		my @out = sort by_priority grep {$cache{$_}++; $cache{$_} == 1 && $minfreq->{$_} < $e_threashold} @hits;
		my $le = (@out > $cs_max)?($cs_max-1):$#out;
		# print "\tbcs\t", join(" % ", (map {$prfx.$convtable{$_}.' ['.$minfreq->{$_}.':'.$minword->{$_}.']'} @out[0..$le]));
		if(defined $out[0] && $avoidcsFlag && $minfreq->{$out[0]} == -1 && $negative_min_words{$minword->{$out[0]}}){
		    $match ='no_hit';
		    $result = $oq;
		    $info = 'bcs_avoidance: '. $query;
		}else{
		    $match = 'bcs';
		    $result = defined $out[0] ? join(" @@ ", map {$prfx. $_} keys %{$convtable{$out[0]}}) : $oq;
		    if(defined $out[0]){
			$info   = join(" % ", (map {join(" @@ ", map {$prfx. $_} keys %{$convtable{$_}}).' ['.$minfreq->{$_}.':'.$minword->{$_}.']'} @out[0..$le]));
		    }else{
			$info   = "Cosine_Sim_To:".join(" % ", @$retr_e);
		    } 
		}
	    } else {
		# print "\tno_hit\t";
		$match  = 'no_hit';
		$result = $oq;
	    }
	}
    }
    # print "\n";
    if($enzymeHash{lc($result)}){
	$info .= " [Enzyme name]";
    }
    $result = b2a($result);
    return({'query'=> $oq, 'result' => $result, 'match' => $match, 'info' => $info, 'result_array' => \@results});
}

sub by_priority {
  #my $minfreq = shift;
  #    my $cosdist = shift;
      
      #  $minfreq->{$a} <=> $minfreq->{$b} || $cosdist->{$b} <=> $cosdist->{$a} || $a =~ y/ / / <=> $b =~ y/ / /
      ## $cosdist->{$b} <=> $cosdist->{$a} || $minfreq->{$a} <=> $minfreq->{$b} || $a =~ y/ / / <=> $b =~ y/ / /
        guideline_penalty($a) <=> guideline_penalty($b)
         or 
        $minfreq->{$a} <=> $minfreq->{$b}
         or 
        $cosdist->{$b} <=> $cosdist->{$a}
         or 
        $a =~ y/ / / <=> $b =~ y/ / /
}

sub guideline_penalty {
 my $result = shift; 
 my $idx = 0;

#1. (酵素名辞書に含まれている場合)
 $idx-- if $enzymeHash{lc($result)};

#2. 記述や句ではなく簡潔な名前を用いる。
 $idx++ if $result =~/ (of|or|and) /;
#5. タンパク質名が不明な場合は、 産物名として、"unknown” または "hypothetical protein”を用いる。今回の再アノテーションでは、"hypothetical protein”の使用を推奨する。
 $idx++ if $result =~/(unknown protein|uncharacterized protein)/;
#7. タンパク質名に分子量の使用は避ける。例えば、"unicornase 52 kDa subunit”は避け、"unicornase subunit A” 等と表記する。
 $idx++ if $result =~/\d+\s*kDa/;
#8. 名前に“homolog”を使わない。
 $idx++ if $result =~/homolog/;
#9. 可能なかぎり、コンマを用いない。
 $idx++ if $result =~/\,/;
#12. 可能な限りローマ数字は避け、アラビア数字を用いる。
 $idx++ if $result =~/[I-X]/;
#16. ギリシャ文字は、小文字でスペルアウトする（例：alpha）。ただし、ステロイドや脂肪酸代謝での「デルタ」は例外として語頭を大文字にする（Delta）。さらに、番号が続いている場合、ダッシュ" -“の後に続ける（例：unicornase alpha-1）。
 $idx++ if $result =~/(\p{Greek})/;


#3. 理想的には命名する遺伝子名（タンパク質名）はユニークであり、すべてのオルソログに同じ名前がついているとよい。
#4. タンパク質名に、タンパク質の特定の特徴を入れない。 例えば、タンパク質の機能、細胞内局在、ドメイン構造、分子量やその起源の種名はノートに記述する。
#6. タンパク質名は、対応する遺伝子と同じ表記を用いる。ただし，語頭を大文字にする。
#10. 語頭は基本的に小文字を用いる。（例外：DNA、ATPなど）
#11. スペルはアメリカ表記を用いる。→ 実装済み（b2a関数の適用）
#13. 略記に分子量を組み込まない。
#14. 多重遺伝子ファミリーに属するタンパク質では、ファミリーの各メンバーを指定する番号を使用することを推奨する。
#15. 相同性または共通の機能に基づくファミリーに分類されるタンパク質に名前を付ける場合、"-"に後にアラビア数字を入れて標記する。（例："desmoglein-1", "desmoglein-2"など）
#17. アクセント、ウムラウトなどの発音区別記号を使用しない。多くのコンピュータシステムは、ASCII文字しか判別できない。
#18. 複数形を使用しない。"ankyrin repeats-containing protein 8" は間違い。
#19 機能未知タンパク質のうち既知のドメインまたはモチーフを含む場合、ドメイン名を付して名前を付けてもよい。例えば "PAS domain-containing protein 5" など。
 return $idx;
}


sub getScore {
    my $retr = shift;
    my $qtms = shift;
    my $minf = shift;
    my $query = shift;
    my (%minfreq, %minword, %ifhit, %cosdistance);
    # 対象タンパク質のスコアは、当該タンパク質を構成する単語それぞれにつき、検索対象辞書中での当該単語の出現頻度のうち最小値を割り当てる
    # 最小値を持つ語は $minword{$_} に代入する
    # また、検索タンパク質名を構成する単語が、検索対象辞書からヒットした各タンパク質名に含まれている場合は $ifhit{$_} にフラグが立つ

    #全ての空白を取り除く処理をした場合への対応
    my $wospct = ($minf)? \%wospconvtableD : \%wospconvtableE;
    #####
    for (@$retr){
	my $wosp = $_;               # <--- 全ての空白を取り除く処理をした場合への対応
	for (keys %{$wospct->{$_}}){ # <--- 全ての空白を取り除く処理をした場合への対応
	    $cosdistance{$_} = $cosine_object->similarity($query, $wosp, $n_gram);
	    my $score = 100000;
	    my $word = '';
	    my $hitflg = 0;
	    for (split){
		my $h = $histogram{$_} // 0;
		if($qtms->{$_}){
		    $hitflg++;
		}else{
		    $h += 10000;
		}
		if($score > $h){
		    $score = $h;
		    $word = $_;
		}
	    }
	    $minfreq{$_} = $score;
	    $minword{$_} = $word;
	    $ifhit{$_}++ if $hitflg;
	}                            # <--- 全ての空白を取り除く処理をした場合への対応
    }
    # 検索タンパク質名を構成する単語が、ヒットした各タンパク質名に複数含まれる場合には、その中で検索対象辞書中での出現頻度スコアが最小であるものを採用する
    # そして最小の語のスコアは-1とする。
    my $leastwrd = '';
    my $leastscr = 100000;
    for (keys %ifhit){
	if($minfreq{$_} < $leastscr){
	    $leastwrd = $_;
	    $leastscr = $minfreq{$_};
	}
    }
    if($minf && $leastwrd){
	for (keys %minword){
	    $minfreq{$_} = -1 if $minword{$_} eq $minword{$leastwrd};
	}
    }
    return (\%minfreq, \%minword, \%ifhit, \%cosdistance);
}

1;
__END__

=head1 NAME

Protein Definition Normalizer

=head1 SYNOPSIS

normProt.pl -t0.7

=head1 ABSTRACT

配列相同性に基いて複数のプログラムにより自動的に命名されたタンパク質名の表記を、既に人手で正規化されている表記を利用して正規形に変換する。

=head1 COPYRIGHT AND LICENSE

Copyright by Yasunori Yamamoto / Database Center for Life Science
このプログラムはフリーであり、また、目的を問わず自由に再配布および修正可能です。

=cut
