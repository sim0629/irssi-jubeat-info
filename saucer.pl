#!/usr/bin/perl -CA

use DBI qw(:sql_types);
use Digest::MD5 qw(md5_hex);
use Encode;
use HTTP::Request::Common;
use JSON;
use LWP::UserAgent;
use Time::HiRes;
use Try::Tiny;

my $MAX_NUM_OF_ROWS = 5;
my $MAX_COMMAND_DISPLAY_LENGTH = 20;
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
        ,rating TEXT
        ,date DATE
        ,fc INT
        ,artist TEXT
        ,bpm TEXT
        ,bpm_min INT
        ,bpm_max INT
        ,level INT
        ,notecount INT
        ,user_name TEXT
        ,great REAL
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
        ,rating
        ,date
        ,fc
        ,artist
        ,bpm
        ,bpm_min
        ,bpm_max
        ,level
        ,notecount
        ,user_name
        ,great
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
        ,?
        ,?
    )") or die $dbh->errstr();

    my $request = GET "http://jubeat.apt-get.kr/saucer/api.php?name=${user}&music_detail=1";
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

        my $great;
        if($notecount) {
            $great = (1000000 - $score) / ((900000 / $notecount) * 0.3);
            $great = int($great * 10) / 10;
        }

        my $rating;
        if($score) {
            if($score < 500000) { $rating = "E"; }
            elsif($score < 700000) { $rating = "D"; }
            elsif($score < 800000) { $rating = "C"; }
            elsif($score < 850000) { $rating = "B"; }
            elsif($score < 900000) { $rating = "A"; }
            elsif($score < 950000) { $rating = "S"; }
            elsif($score < 980000) { $rating = "SS"; }
            elsif($score < 1000000) { $rating = "SSS"; }
            else { $rating = "EXC"; }
        }

        $sth->execute(
             $id
            ,$music
            ,$difficulty
            ,$score
            ,$rating
            ,$date
            ,$fc
            ,$artist
            ,$bpm
            ,$bpm_min
            ,$bpm_max
            ,$level
            ,$notecount
            ,$user_name
            ,$great
        ) or die $dbh->errstr();
    }
}

sub execute {
    my ($dbh, $sth) = @_;

    my @messages = ();

    $sth->execute() or die $dbh->errstr();
    while(my (@result) = $sth->fetchrow_array()) {
        my $message = join(', ', @result);
        push(@messages, $message);
    }

    return @messages;
}

sub select_query {
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
            $dbh->disconnect();
            return;
        }
    }
    my $display_command = $command;
    my $command_length = length($command);
    if($command_length > $MAX_COMMAND_DISPLAY_LENGTH + 3) {
        $display_command = substr($command, 0, $MAX_COMMAND_DISPLAY_LENGTH);
        $display_command .= "...";
    }
    $callback->("[Loading] ${display_command}");

    for my $user (@users) {
        fetch($dbh, $user);
    }
    my @messages = execute($dbh, $sth);

    my $messages_count = @messages;
    my $count = 0;

    for my $message (@messages) {
        Time::HiRes::sleep($FLOOD_DELAY);
        $count += 1;
        $message .= " [DONE]" if($count == $messages_count);
        $callback->("[${count}] $message");
        last if($count >= $MAX_NUM_OF_ROWS);
    }

    if($messages_count == 0) {
        $callback->("[EMPTY]");
    }elsif($messages_count > $MAX_NUM_OF_ROWS) {
        my $code = $command."\n\n".join("\n", @messages);
        my $ua = LWP::UserAgent->new();
        my $response = $ua->post(
            "http://paste.neria.kr/index.php",
            Content => [
                "parent_id" => "",
                "format" => "text",
                "code2" => $code,
                "poster" => "",
                "paste" => "Submit",
                "expiry" => "d",
                "password" => ""
            ]
        );
        my $url = "";
        if($response->code == 302) {
            $url = "http://paste.neria.kr/".($response->header("Location"));
        }
        my $suppressed_count = $messages_count - $MAX_NUM_OF_ROWS;
        $callback->("${suppressed_count} more... ${url}");
    }

    $dbh->disconnect();
}

sub update_query {
    my ($command, $callback) = @_;
    if($command =~ /^(update\s+(\S+))(\s|$)/) {
        my $real_command = $1;
        my $name = $2;
        my $result = "Fail";
        my $request = PUT "http://jubeat.apt-get.kr/saucer/api.php",
                          Content => "name=${name}";
        my $ua = LWP::UserAgent->new;
        $ua->agent('Mozilla/5.0');
        my $response = $ua->request($request);
        if($response->is_success) {
            my $string = $response->decoded_content;
            $result = "OK" if($string);
        }
        $callback->("[${result}] ${real_command}");
    }
}

sub main {
    my ($command, $callback) = @_;
    if($command =~ /^select/) {
        select_query($command, $callback);
    }elsif($command =~ /^update/) {
        update_query($command, $callback);
    }
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
        return if $text !~ /\?(.+)$/i;
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
