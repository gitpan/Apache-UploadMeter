package Apache::UploadMeter;

use strict;
use warnings;
use vars qw($VERSION @ISA @EXPORT @EXPORT_OK %EXPORT_TAGS);
use mod_perl 0.95 qw(PerlStackedHandlers PerlSections PerlHeaderParserHandler PerlFixupHandler PerlHandler);
use Apache::Constants qw(OK DECLINED HTTP_MOVED_TEMPORARILY BAD_REQUEST NOT_FOUND);
use Apache::Util qw(escape_uri);
use Apache::Request;
use Apache::SSI;
use Digest::MD5 qw(md5_hex);
use Cache::FileCache;

BEGIN {
    use Exporter ();
    $VERSION=0.17 ;
    @ISA=qw(Exporter Apache::SSI);
    @EXPORT=();
    @EXPORT_OK=qw ( );
    %EXPORT_TAGS=();
}

### Version History
# 0.10 : Oct  28, 2001 - Restarted when file got wiped :-(
# 0.11 : Nov  12, 2001 - Added new SSI to replace JS handler and increase unique-id reliability
# 0.12 : Nov  17, 2001 - Switched output to XML
# 0.14 : Dec  11, 2001 - Added configuration code
# 0.15 : Dec  12, 2001 - Improved configuration code to auto-detect namespace (for possible future subclassing)
# 0.15a: Dec  30, 2001 - Recovered version 0.15 (Thanks - you know who you are if you made it possible) and moved namespace to sourceforge.
# 0.16a: Jan  08, 2002 -  Added basic JIT handlers to configuration
# 0.17 : Jan  13, 2002 - Cleaned up some more code and documentation - seems beta-able


### Globals
my %cache_options=('default_expires_in'=>900,'auto_purge_interval'=>60,'namespace'=>'apache_umeter'); #If the hooks don't get called in 15 minute, assume it's done
my $MaxTime="+900";
my $TIMEOUT=15;

### Handlers
### Upload meter generator - Master process
sub u_handler($)
{
    ### Upload hook handler
    my $hook_handler= sub {
	my ($upload, $buf, $len, $hook_data)=@_;
        my $hook_cache=new Cache::FileCache(\%cache_options);
        unless ($hook_cache) {
	    Apache->log_error("Could not instantiate FileCache.  Exiting.");
	    return DECLINED; 
	}
	my $oldlen=$hook_cache->get($hook_data."len") || 0;
	$len=$len+$oldlen;
	if ($oldlen==0)
	{
	    warn ("Instantiating cache for $hook_data") if (_conf("DEBUG")>0);
	    my $name=$upload->filename;
	    $hook_cache->set($hook_data."name",$name);
	}
	warn ("Updating cache: $hook_data LEN --> $len") if (_conf("DEBUG")>2);
        $hook_cache->set($hook_data."len",$len);
    };
    my $r=shift;
    my %args=$r->args;
    return BAD_REQUEST unless defined($args{hook_id});
    my $u_id=$args{hook_id};
    $r->pnotes("u_id" => $u_id);
    my $hook_cache=new Cache::FileCache(\%cache_options);
    unless ($hook_cache) {
	Apache->log_error("Could not instantiate FileCache.  Exiting.");
        return DECLINED; 
    }
    my $TempDir=_conf("TempDir") || undef;
    my $q;
    if (defined($TempDir)) {
        $q=Apache::Request->instance($r, HOOK_DATA=>$u_id,UPLOAD_HOOK=>$hook_handler, TEMP_DIR=>$TempDir);
    } else {
	$q=Apache::Request->instance($r, HOOK_DATA=>$u_id,UPLOAD_HOOK=>$hook_handler);
    }
    my $rsize=$r->header_in("Content-Length");
    $hook_cache->set($u_id."size",$rsize);
    return OK;
}

### Upload FixupHandler - make sure that uploadsize get's updated to proper size and that size is set to something (Even 0)

sub ufu_handler($)
{
    my $r=shift;
    my $q=Apache::Request->instance($r);
    my $u_id=$r->pnotes("u_id");
    my $upload=$q->upload; # Should only return once upload is completed
    my $hook_cache=new Cache::FileCache(\%cache_options);
    unless ($hook_cache) {
	Apache->log_error("Could not instantiate FileCache.  Exiting.");
        return DECLINED;
    }
    my $size=$hook_cache->get($u_id."size");
    $hook_cache->set($u_id."len",$size);
    return OK;
}    

### Upload meter generator - Slave process
sub um_handler($)
{
    my $r=shift;
    $r->no_cache(1);
    my $q=Apache::Request->new($r);
    my $hook_id=$q->param('hook_id') || undef;
    my $initial_request=$q->param('returned') || 1;
    return BAD_REQUEST unless defined($hook_id);
    my $hook_cache=new Cache::FileCache(\%cache_options);
    unless ($hook_cache) {
    	$r->log_error("Could not instantiate FileCache.  Exiting.");
    	return DECLINED;
    }
    my $len=$hook_cache->get($hook_id."len") || undef;
    if (!(defined($len))) {
	my $problem=1;
	if ($initial_request) {
	    my $count=0;
	    my $i;
	    my $c=$r->connection;
	    for ($i=0;$i<$TIMEOUT;$i++)
	    {
		$len=$hook_cache->get($hook_id."len") || undef;
		if (defined($len)) {
		    $problem=0;
		    last;
		}
		warn "Waiting for upload cache $hook_id to initialize ($i / $TIMEOUT)..." if (_conf("DEBUG")>1);
		sleep 1;
		last if $c->aborted;
	    }
	}
	if ($problem) {
	    $r->custom_response(NOT_FOUND,"This upload meter is either invalid, or has expired.");
            return NOT_FOUND;
	}
    }
    my $size=$hook_cache->get($hook_id."size") || "Unknown";
    my $fname=$hook_cache->get($hook_id."name") || "Unknown";
    my $s=$r->server;
    my $name=$s->server_hostname;
    my $args=$r->args;
    if ($initial_request) { $args=$args.(defined($args)?"&":"")."returned=1";}
    $r->header_out("Refresh"=>"5;url=".($ENV{HTTPS}?"https":"http")."://".$name.$r->uri."?".escape_uri($args));
    $r->send_http_header('text/xml');
    return OK if $r->header_only;
    {
	print <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE APACHE_UPLOADMETER SYSTEM "http://apache-umeter.sourceforge.net/apache_umeter.dtd

">
<APACHE_UPLOADMETER HOOK_ID="$hook_id">
    <FILE NAME="$fname">
	<RECIEVED>$len</RECIEVED>
	<TOTAL>$size</TOTAL>
    </FILE>
</APACHE_UPLOADMETER>
EOF
    }
    return OK;
}

sub uf_handler($)
{
    my $r=shift;
    $r->no_cache(1); # CRITICAL!  No caching allowed!
    my $digest=md5_hex(time,(defined $r->subprocess_env('HTTP_HOST') ? $r->subprocess_env('HTTP_HOST') : 0),(defined $r->subprocess_env('HTTP_X_FORWARDED_FOR') ?$r->subprocess_env('HTTP_X_FORWARDED_FOR') : 0 ));
    $r->pnotes("u_id"=>$digest);
    return OK;
}

### Support handlers (for debugging)

sub r_handler($)
{
    my $r=shift;
    my $q=Apache::Request->instance($r);
    $r->no_cache(1);
    my $upload=$q->upload;
    my $name=$upload->filename;
    my $size=$upload->size;
    $r->send_http_header('text/plain');
    return OK if $r->header_only;
    print "Done.\n$name\n$size\n";
    return OK;
}

### SSI-Handlers

sub ssi_uploadform($$)
{
    my ($self,$attr)=@_;
    my $output=undef;
    my $r=Apache->request;
    my $u_id=$r->pnotes('u_id') || undef;
    if (!(defined($u_id))) {
	### FIX THE ERROR
	$r->log_error("Apache::Upload - No u_id in pnotes table. Make sure you ran configure()");
	return "<!-- No u_id in pnotes -->";
    }
    my $script=$attr->{script} || _conf("UploadScript");
    my $meter=$attr->{meter} || _conf("UploadMeter");
    $output="
<SCRIPT LANGUAGE=\"JavaScript\">
<!-- Cloaking...
function openUploadMeter()
{
    uploadWindow=window.open(\"${meter}?hook_id=${u_id}\",\"_new\",\"toolbar=no,location=no,directories=no,status=yes,menubar=no,scrollbars=no,resizeable=no,width=450,height=150\");
}
// End cloaking-->
</SCRIPT>
<NOSCRIPT>You must use a JavaScript-enabled browser to use this page properly</NOSCRIPT>
<FORM ACTION=\"${script}?hook_id=${u_id}\" METHOD=\"POST\" ENCTYPE=\"multipart/form-data\" onSubmit=\"openUploadMeter()\">
";
    return $output;
}

### Configuration routines

sub upload_jit_handler($)
{
    my $r=shift;
    $r->push_handlers("PerlFixupHandler",\&ufu_handler);
    $r->push_handlers("PerlHandler",\&r_handler);
    $r->handler("perl-script");
    return u_handler($r);
}

sub meter_jit_handler($)
{
    my $r=shift;
    $r->handler("perl-script");
    $r->push_handlers("PerlHandler",\&um_handler);
    return DECLINED;
}
    
sub form_jit_handler($)
{
    my $r=shift;
    $r->handler("perl-script");
    $r->push_handlers("PerlFixupHandler",\&uf_handler);
    $r->set_handlers("PerlHandler",[__PACKAGE__]);
    return DECLINED;
}

sub configure()
{
    my $namespace=__PACKAGE__;
    my ($UploadScript,$UploadMeter,$UploadForm)=(_conf("UploadScript"),_conf("UploadMeter"),_conf("UploadForm"));
    warn "Configuring for $namespace v$VERSION $UploadScript - $UploadMeter - $UploadForm" if (_conf("DEBUG")>1);
    package Apache::ReadConfig;
    no strict;
    $Location{$UploadScript} = {
	Options => '+ExecCGI',
	#PerlHeaderParserHandler => $namespace."::u_handler",
	PerlHeaderParserHandler => $namespace."::upload_jit_handler",
    };
    $Location{$UploadMeter} = {
	Options => '+ExecCGI',
	PerlHeaderParserHandler => $namespace."::meter_jit_handler",
    };
    $Location{$UploadForm} = {
	Options => '+ExecCGI',
	PerlHeaderParserHandler => $namespace."::form_jit_handler",
    };
    return 1;
}

sub _conf($)
{
    my $arg=shift;
    return eval("\$".__PACKAGE__."::".$arg);
}


# Preloaded methods go here.

1;
__END__

=head1 NAME

Apache::UploadMeter - Apache module which implements an upload meter for form-based uploads

=head1 SYNOPSIS

  (in mod_perl_start.pl)
  use Apache::UploadMeter;
  
  $Apache::UploadMeter::UploadForm='/form.html';
  $Apache::UploadMeter::UploadScript='/perl/upload';
  $Apache::UploadMeter::UploadMeter='/perl/meter';
  
  Apache::UploadMeter::configure;

  (in /form.html)

  <!--#uploadform-->
  <INPUT TYPE="FILE" NAME="theFile"/>
  <INPUT TYPE="SUBMIT"/>
  </FORM>

=head1 DESCRIPTION

Apache::UploadMeter is a mod_perl module which implements a status-meter/progress-bar
to show realtime progress of uploads done using a form with enctype=multipart/formdata.

Since the module uses quite a few distinct URIs to run, as well as the need to chain
to various parts of the Apache request phase and the need to insert data into existing
HTML changes, it might seem a trifle difficult to set up at first glance.  However,
much effort has been made in minimizing the effort required to do this.  All that is
needed is to tell the module where the different URLs are during server startup, and
Apache::UploadMeter will insert the proper hooks for the different URLs automatically.

The only changes needed to be made to existing pages and/or scripts is the replacement
of the existing E<lt>FORME<gt> tag, which is done automatically the a special SSI directive
E<lt>!--#uploadform--E<gt> instead of the existing E<lt>FORME<gt> tag.

NOTE: To use this, mod_perl MUST be built with StackedHandlers enabled.

=head1 INTERFACE

=over

=item *

$Apache::UploadMeter::UploadForm

This should point to the URI on the server which contains the upload form with the special E<lt>!--#uploadform--E<gt> tag.  Note that there should NOT be an opening E<lt>FORME<gt> tag, but there SHOULD be a closing E<lt>/FORME<gt> tag on the HTML page.

=item *

$Apache::UploadMeter::UploadScript

This should point to the target (eg, ACTION) of the upload form.

=item *

$Apache::UploadMeter::UploadMeter

This should point to an unused URI on the server. This URI will be used to provide the progress-meter window.

=item *

$Apache::UploadMeter::TempDir

Can be used to set the TEMP_DIR directive in Apache::Request->new

=back

=head1 AUTHOR AND COPYRIGHT

Copyright (c) 2001, 2002 Issac Goldstand E<lt>margol@beamartyr.netE<gt> - All rights reserved.

This library is free software. It can be redistributed and/or modified
under the same terms as Perl itself.


=head1 SEE ALSO

Apache::Request(3)

=cut
