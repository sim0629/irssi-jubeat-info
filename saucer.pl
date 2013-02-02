#!/usr/bin/perl -CA

use DBI qw(:sql_types);
use HTTP::Request;
use LWP::UserAgent;
use Mojo::DOM;
use Time::HiRes;
use Try::Tiny;

my $MAX_NUM_OF_ROWS = 5;
my $FLOOD_DELAY = 0.5;

sub quote {
    my ($dbh, $identifier) = @_;
    $identifier =~ s/^\s+//;
    $identifier =~ s/\s+$//;
    return $dbh->quote_identifier($identifier);
}

sub create_table {
    my ($dbh, $user) = @_;
    my $safe_user = quote($dbh, $user);

    $dbh->do("CREATE TABLE ${safe_user} (
         id INTEGER
        ,name TEXT
        ,difficulty TEXT
        ,level INTEGER
        ,score INTEGER
        ,fullcombo INTEGER
        ,rank INTEGER
        ,delta INTEGER
    )") or die $dbh->errstr();
}

sub fetch {
    my ($dbh, $user) = @_;
    my $safe_user = quote($dbh, $user);

    my $sth = $dbh->prepare("INSERT INTO ${safe_user} (
         id
        ,name
        ,difficulty
        ,level
        ,score
        ,fullcombo
        ,rank
        ,delta
    ) VALUES (
         ?
        ,?
        ,?
        ,?
        ,?
        ,?
        ,?
        ,?
    )") or die $dbh->errstr();

    my $request = HTTP::Request->new(GET => "http://saucer.isdev.kr/${user}/all-default");
    my $ua = LWP::UserAgent->new;
    $ua->agent('Mozilla/5.0');
    my $response = $ua->request($request);
    die 'http request' if (!$response->is_success);
    my $string = $response->decoded_content;
    my $dom = Mojo::DOM->new;
    $dom->parse($string);
    for my $tr ($dom->at('#music_list tbody')->find('tr')->each) {
        next if $tr->attrs('class') eq 'other';
        my $a_song = $tr->at('.title > a');

        my $href = $a_song->attrs('href');
        my $number = substr($href, rindex($href, '-') + 1);

        my $name = $a_song->text;

        my $difficulty_number = 0;
        for my $difficulty ('bsc', 'adv', 'ext') {
            $td = $tr->at(".${difficulty}");

            my $level = $td->at('.level')->text;

            my $score = $td->at('.score')->text;
            $score =~ s/,//g;

            my $div_bottom = $td->at('.bottom');
            my $rank = substr($div_bottom->text, 1);

            my $fullcombo = ($td->at('.mark')->text eq 'FC') ? 1 : 0;

            my $text = $td->at('.text')->text;
            my $delta = 0;
            if($text =~ /^[\+\-]([0-9,]+)/) {
                $delta = $1;
                $delta =~ s/,//g;
            }

            $sth->execute(
                 $number.$difficulty_number
                ,$name
                ,$difficulty
                ,$level
                ,$score
                ,$fullcombo
                ,$rank
                ,$delta
            ) or die $dbh->errstr();

            $difficulty_number += 1;
        }
    }
}

sub execute {
    my ($dbh, $sth) = @_;

    my @messages = ();

    $sth->execute() or die $dbh->errstr();
    my $count = 0;
    while(my (@result) = $sth->fetchrow_array()) {
        $count += 1;
        next if($count > $MAX_NUM_OF_ROWS);
        my $message = "[${count}] ".join(', ', @result);
        push(@messages, $message);
    }
    my $suppressed_count = $count - $MAX_NUM_OF_ROWS;
    if($suppressed_count > 0) {
        my $message = "${suppressed_count} more...";
        push(@messages, $message);
    }

    return @messages;
}

sub main {
    my ($command, $callback) = @_;

    my $dbh = DBI->connect("dbi:SQLite:dbname=:memory:", "", "")
        or die $dbh->errstr();
    $dbh->{PrintError} = 0;
    $dbh->{sqlite_unicode} = 1;

    my @users = ();
    my $sth = undef;
    until($sth = $dbh->prepare($command)) {
        my $errstr = $dbh->errstr();
        if($errstr =~ /no such table:(\s*)(\w+)/) {
            my $user = $+;
            create_table($dbh, $user);
            push(@users, $user);
        }else {
            $callback->("[Error] ${errstr}");
            return;
        }
    }
    $callback->("[Loading] ${command}");

    for my $user (@users) {
        fetch($dbh, $user);
    }
    my @messages = execute($dbh, $sth);

    my $messages_count = @messages;
    if($messages_count == 0) {
        $callback->("[EMPTY]");
    }
    for my $message (@messages) {
        $messages_count -= 1;
        if($messages_count == 0) {
            $message = "${message} [DONE]";
        }
        $callback->($message);
    }

    $dbh->disconnect();
}

sub event_privmsg {
    my ($server, $data, $nick, $address) = @_;
    my ($target, $text) = split(/ :/, $data, 2);

    if($target =~ /^#/) {
        return if $target !~ /^#jubeater$/i;
    }else {
        $target = $nick;
    }

    try {
        return if $text !~ /\?(select.+)$/i;
        my $command = $+;

        my $irssi_callback = sub {
            my ($message) = @_;
            $server->command("MSG ${target} ${message}");
            Time::HiRes::sleep($FLOOD_DELAY);
        };
        main($command, $irssi_callback);
    }catch {
        $server->command("MSG ${target} [Fail]");
        # TODO: error message
    }
}

if(caller) {
    require Irssi;
    Irssi::signal_add("event privmsg", "event_privmsg");
}else {
    if(@ARGV < 1) {
        die "no command";
    }
    binmode(STDOUT, ":utf8");
    my $print_callback = sub {
        my ($message) = @_;
        print "${message}\n";
    };
    main(@ARGV[0], $print_callback);
}
