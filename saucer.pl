#!/usr/bin/perl -CA

use DBI qw(:sql_types);
use Digest::MD5 qw(md5_hex);
use Encode;
use HTTP::Request;
use JSON;
use LWP::UserAgent;
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
         id TEXT
        ,music TEXT
        ,difficulty TEXT
        ,score INT
        ,date DATE
        ,fc INT
        ,artist TEXT
        ,bpm TEXT
        ,bpm_min INT
        ,bpm_max INT
        ,level INT
        ,notecount INT
        ,user_name TEXT
    )") or die $dbh->errstr();
}

sub fetch {
    my ($dbh, $user) = @_;
    my $safe_user = quote($dbh, $user);

    my $sth = $dbh->prepare("INSERT INTO ${safe_user} (
         id
        ,music
        ,difficulty
        ,score
        ,date
        ,fc
        ,artist
        ,bpm
        ,bpm_min
        ,bpm_max
        ,level
        ,notecount
        ,user_name
    ) VALUES (
         ?
        ,?
        ,?
        ,?
        ,?
        ,?
        ,?
        ,?
        ,?
        ,?
        ,?
        ,?
        ,?
    )") or die $dbh->errstr();

    my $request = HTTP::Request->new(GET => "http://jubeat.apt-get.kr/saucer/api.php?name=${user}&music_detail=1");
    my $ua = LWP::UserAgent->new;
    $ua->agent('Mozilla/5.0');
    my $response = $ua->request($request);
    die 'http request' if (!$response->is_success);
    my $string = $response->decoded_content;
    my $json = JSON::from_json($string);
    my $user_name = $json->{"data"}->{"user_name"};
    my $history = $json->{"data"}->{"history"};
    foreach my $element (@$history) {
        my $music = $element->{"music"};
        my $difficulty = $element->{"difficulty"};
        my $score = $element->{"score"};
        my $date = $element->{"date"};
        my $fc = $element->{"fc"};
        my $artist = $element->{"artist"};
        my $bpm = $element->{"bpm"};
        my $level = $element->{"level"};
        my $notecount = $element->{"notecount"};

        my $id = substr(md5_hex(encode("utf8", $music), $difficulty), 0, 8);
        my $bpm_min = $bpm;
        my $bpm_max = $bpm;
        if($bpm =~ /(\d+)-(\d+)/) {
            $bpm_min = $1;
            $bpm_max = $2;
        }

        $sth->execute(
             $id
            ,$music
            ,$difficulty
            ,$score
            ,$date
            ,$fc
            ,$artist
            ,$bpm
            ,$bpm_min
            ,$bpm_max
            ,$level
            ,$notecount
            ,$user_name
        ) or die $dbh->errstr();
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
    if($count == 0) {
        my $message = "[EMPTY]";
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
    for my $message (@messages) {
        Time::HiRes::sleep($FLOOD_DELAY);
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
