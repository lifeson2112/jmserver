package JMServer;

use strict;
use Socket;
use CGI::Ex::Dump qw(debug);
use Data::Dumper;
use IO::Socket::INET;
use URI::Escape;
use Parallel::ForkManager;

sub new {
    my $class = shift;
    my $args = shift;
    defined $args->{'docroot'} && -e $args->{'docroot'}
        or die ("please specify a docroot");

    return bless $args,$class; 
}

sub config {
    my $self = shift;
    return {
        docroot       => $self->{'docroot'} ,
        default_file  => $self->{'default_file'} || '/',
        index_file    => $self->{'index_file'} || 'index.html',
        default_port  => $self->{'port'} || 2112,
        indexes       => defined $self->{'indexes'} ? $self->{'indexes'} : 1, #show indexof
        max_conn      => $self->{'max_conn'} || 30,
    }
}

#TODO make this further configurable via '.htaccess' files
#map extensions to mime_types
sub mime_hash {
    return {
        html => 'text/html',
        pdf  => 'application/pdf',
        txt  => 'text/plain',
        mp3  => 'audio/mpeg3',
        zip  => 'application/zip',
        jpg  => 'image/jpeg',
        jpeg => 'image/jpeg',
        png  => 'image/png',
        gif  => 'image/gif',
    }
}

#if you don't specify a mime_type then it needs to be printed in the script.
#TODO make this configurable via '.htaccess' files
sub exec_hash {
    return {
        pl => {
            path => '/usr/bin/perl',
#            mime_type => 'text/html',
        },
        #allow execution of extensionless files (requires shebang)
        ''  => {
            path => '',
        }
    }
}

sub start {
    my $self = shift;
    my $args = shift;
    my $config = $self->config; 

    #set up stuff which will be served at the base uri
    my $d_file_path = $args->{'file_path'} || $config->{'default_file'};
    my $port = $args->{'port'} || $config->{'default_port'};
 
    my $socket = new IO::Socket::INET (
        LocalHost => '0.0.0.0',
        LocalPort => $port,
        Proto => 'tcp',
        Listen => 5,
        Reuse => 1
    ) or die("Could not create socket on port $port!!\n");


    #print out the location we are serving from
    my $localip = (grep {$_ =~ m/inet addr:127/} `ifconfig`)[0];
    $localip =~ s/.*inet addr:(\d{1,3}\.\d{1,3}\.\d{1,3}\.\d{1,3}).*/$1/g;
    chomp $localip;

    #grab default file and store it in memory (we won't cache server executables though)
    my $d_content;
    open SERVEFILE, "<$d_file_path";
    read(SERVEFILE,$d_content,-s $d_file_path);
    close(SERVEFILE);

    $self->env({DOCUMENT_ROOT => $self->{'docroot'}});

    my $farker = Parallel::ForkManager->new($self->config->{'max_conn'});
    
    # wait to accept a connection
    while(1){

        my $client_socket;
        $client_socket = $socket->accept();

        #fork each individual session
        %ENV = ();
        $farker->start and next;

        #grab the remote ip
        my $remote_ip = $client_socket->peerhost;
        #use socket as stdout
        select $client_socket;

        #get any request headers
        my $stdin;
        my $headers = '';
        my $post_data = '';
        my $is_post = 0;
        my $grab_post = 0;
        my $i = 0;
        my $content_length = 0;

        while( $stdin = <$client_socket> ){
            $is_post = 1 if !$i && $stdin =~ m/^POST/i;

            ($content_length) = $stdin =~ m/content-length: (\d.*)/i
                if $stdin =~ m/content-length:/i;

            $headers = $headers.$stdin;

            $stdin =~ s/(\n|\r)//g;
            if ($stdin eq ''){
                read $client_socket, $post_data, $content_length if $is_post;
                last;
            }                    
#            last if $i++ > 100;
        }

        #Grab any pertinent information from headers
        my @request_line = (split(" ",(split("\n",$headers))[0])) ;
        my $request_method = $request_line[0] || ''; 
        my $request_uri = $request_line[1] || '';

        $self->env({REQUEST_URI => $request_uri}); #leave query string in env's request_uri
        my ($script_name,$query_string) = split(/\?/,$request_uri);
        $request_uri = $script_name;
        #set environment string which will be used for cgi scripts
        $self->env({
            REMOTE_ADDR    => $remote_ip,
            REQUEST_METHOD => $request_method,
            SCRIPT_NAME    => $script_name || '',
            CONTENT_LENGTH => 1000000,
            $query_string ? 
            (QUERY_STRING   => $query_string)
            : (),
        });
        
        #if a request uri is passed in then go ahead and try to serve that file instead
        #if we are given a folder then print a directory index
        if ($request_uri ne '/' && (my $requested_file_path = "$config->{'docroot'}/$request_uri")){
            $self->serve_content({file => $requested_file_path, post_data => $post_data});
            $client_socket->flush;
            close $client_socket;
            $farker->finish;
            next;
        }
        #serve default content
        #Default file does not have to be under the document root, so pass in no_rel
        $self->serve_content({file => $d_file_path , content => $d_content, no_rel => 1, post_data => $post_data });
        $client_socket->flush;
        close $client_socket;
        $farker->finish;
    }

}

sub directory_index{
    my $self = shift;
    my $args = shift;
    my $directory = $args->{'directory'}; 
    $directory =~ s/\/\/*/\//g;
    $directory = $directory."/";
    $directory =~ s/ /\\ /g; #escape whitespace

    #look for index file 
    #if it exists then just serve that instead
    if (-e $directory."/".$self->config->{'index_file'}) {
        $self->serve_content({file => $directory."/".$self->config->{'index_file'}}); 
        return 1; 
    }
    
    #just list folder contents
    my $docroot = $self->config->{'docroot'};
    my @files = <$directory*>;
    print qq{HTTP/1.0 200 OK\nSever:jmiller\nContent-Type: text/html\n\n};
    print qq{<html><head><title>Directory Index</title></head><body>};
    print qq{<h1>Directory Index For $directory</h1>};
    foreach (@files) {
        my $rel_href = $_;
        $rel_href =~ s/$docroot//g;
        $rel_href =~ s/^\/*//g;
        my $file_name = (split("/",$rel_href))[-1];
        print qq{<a href="/$rel_href">$file_name</a><br>};
    }
}

sub error {
    my $self = shift;
    my $args = shift;
    my $code = $args->{'code'} || $self->error({code => 500});
    my $message_hash = {
        404 => "OHNOOO!! CAN'T FIND IT!!",
        403 => "I FORBID THIS!!!",
        401 => "Auth required",
        500 => "EVERYTHING BROKE!!! ...you should probably check logs",
    };
    my $message = $message_hash->{$code} || "No idea what the hell you are trying to do.";
    my $request_uri = $args->{'request_uri'} || '';
    print qq{HTTP/1.0 $code error\nSever:jmiller\nContent-Type: text/html\n\n};
    print qq{<html><head><title>Error</title></head><body><h1>$message</h1>request_uri: $request_uri };
    return 1;
}

sub serve_content {
    my $self = shift;
    my $args = shift;
    #should be relative to docroot when passed in
    my $file_path = $args->{'file'};
    my $docroot = $self->config->{'docroot'};
    #unless we override that restriction
    my $no_rel = $args->{'no_rel'} || undef;
    $file_path =~ s/$docroot//g unless defined $no_rel;
    #make full
    $file_path = $docroot."/$file_path" unless defined $no_rel;
    $file_path = uri_unescape($file_path);
    #grab file from any url arguments
    $file_path = $self->existing_file_from_path($file_path);

    #allow content override (caching);
    my $content = $args->{'content'} || undef;
    
    my $post_data = $args->{'post_data'} || '';

#    my $file_extension = (split(/\./,$file_path))[-1] || '';
    my ($file_extension) = $file_path =~ m/\.([^\/].*)$/i;
    $file_extension ||= '';
    my $mime_type = $self->mime_hash->{$file_extension} || 'application/octet-stream';

    if(-e $file_path && !-d $file_path){
        #first see if we need to execute the target and serve the results.
        my $exec = $self->exec_hash->{$file_extension};
        if (defined $exec && ref $exec eq 'HASH') {
            my $exec_path = $exec->{'path'};
            $mime_type = $exec->{'mime_type'};
            $self->env({gargg => "gargamoth"});
#            my $tmpfile = "/tmp/servertmp";
#            $content = `$env  $exec_path $file_path  $tmpfile`;

            my $postfile = rand(time).time;
            $postfile = "/tmp/$postfile"; 
            open FH , "|$exec_path $file_path > $postfile";
            print FH $post_data;
            close FH;

            open INPUT , $postfile;
            read(INPUT, $content, -s $postfile);
            close INPUT;
        
            unlink $postfile;

        } elsif (!defined $content) {
            #otherwise just serve the file contents
            open SERVEFILE, "<$file_path";
            read(SERVEFILE,$content,-s $file_path);
            close(SERVEFILE);
        }
    } elsif (-d $file_path){
        if($self->{indexes}){
            $self->directory_index({directory => $file_path});
        } else {
            $self->error({code => 403, request_uri => $file_path});
        }
        return 1;
    } elsif (!-e $file_path){
        $self->error({code => 404, request_uri => $file_path});
        return 1;
    }
 
    my $file_name = (split("/",$file_path))[-1];
    my $file_header = "Content-Disposition: inline; filename=\"$file_name\"\n" ;
    my $mime_line = $mime_type ? "Content-Type: $mime_type\n\n" : ''; 
    print qq{HTTP/1.0 200 OK\nSever:jmiller\n${file_header}$mime_line$content};

    return 1;
}

#allows arguments to be passed via url 
#without being misinterpreted as part of the file path
#(/path/to/file/otherarguments/this is actually /path/to/file)
#accepts full paths only
sub existing_file_from_path {
    my $self = shift;
    my $file_path = shift;
    my @parts = split '/' ,$file_path;
    my $new_path = '/';
    my $path_info ;
    foreach (@parts){
        $new_path = $new_path."/$_" if $_ && !defined $path_info ;
        $path_info = $path_info."/$_" if $_ && defined $path_info;
        $path_info = '' if ($_ && -f $new_path && !defined $path_info);
    }
    my $script_name = $ENV{'SCRIPT_NAME'};
    $script_name =~ s/$path_info//g;
    $self->env({PATH_INFO => $path_info});
    $self->env({SCRIPT_NAME => $script_name});
    return $new_path;
}

#set/print string used to pring environment variables.
#Accepts a hash which is then transformed into a string
sub env {
    my $self = shift;
    my $env_hash = shift;
    $self->{'env'} = {
        ref $self->{'env'} eq "HASH" ? %{$self->{'env'}} : (),
        ref $env_hash eq "HASH" ? %$env_hash : (),
    };

    #actually this makes things much easier. Just set the global %ENV
    %ENV = (%ENV,%{$self->{'env'}});

    my $env_string = '';
    foreach (keys %{$self->{'env'}}){
        $env_string = $env_string ."$_=".$self->{'env'}->{$_}." ";
    }

    return {%ENV};
}


1;
