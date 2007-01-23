package Apache::UploadMeter;

use strict;
use warnings;
use vars qw($VERSION @ISA);
use mod_perl2 ();
use Apache2::Const -compile=>qw(:common :context HTTP_BAD_REQUEST OR_ALL EXEC_ON_READ RAW_ARGS);
use APR::Const     -compile => ':common';
use Apache2::RequestRec ();
use Apache2::Log ();
use Apache2::RequestUtil ();
use Apache2::RequestIO ();
use Apache2::Response ();
use Apache2::Filter ();
use Apache2::Module ();
use Apache2::Directive ();
use Apache2::CmdParms ();
use Apache2::ServerRec ();
use Apache2::ServerUtil ();
use APR::Brigade ();
use APR::Bucket ();
use APR::BucketType ();
use APR::BucketAlloc ();

use Apache2::Request ();
use APR::Request ();
use Digest::SHA1 ();
use Cache::FileCache ();
use Number::Format ();
use Date::Format ();
use HTML::Parser ();

BEGIN {
    $VERSION=0.99_05;
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
# 0.21 : Feb   3, 2002 - Prebundled "basic" skin on sourceforge.  Migrate from DTD to schema.  Time/Date formatting currently server-side.
# 0.22 : Feb   3, 2002 - Fixed typo in URI for XSLT
# 0.99_03 : Jan  22, 2007 - Upgraded for mod_perl2; we'll have a stable 1.00 release with a few more fixes here
# 0.99_05 : Jan  23, 2007 - Finished outstanding issues using XML-based meter.

## Presets
our $XSLT="http://apache-umeter.sourceforge.net/apache-umeter-".$VERSION.".xsl";


### Globals
my %cache_options=('default_expires_in'=>900,'auto_purge_interval'=>60,'namespace'=>'apache_umeter','auto_purge_on_get'=>1); #If the hooks don't get called in 15 minute, assume it's done
my $MaxTime="+900";
my $TIMEOUT=15;

### Handlers
sub hook_handler {
    my $r = shift;
    my $hook_data = shift; # joes says libapreq2 should use perl closures for
                           # implementing $hook_data - who am i to argue?
    ### Upload hook handler
    return sub {
	my ($upload, $new_data)=@_;
	my $len = length($new_data);
        my $hook_cache=new Cache::FileCache(\%cache_options);
        unless ($hook_cache) {
	    $r->log_reason("[Apache::UploadMeter] Could not instantiate FileCache.", __FILE__.__LINE__);
	    return Apache2::Const::DECLINED; 
	}
	my $oldlen=$hook_cache->get($hook_data."len") || 0;
	$len=$len+$oldlen;
	if ($oldlen==0)
	{
	    $r->log->notice("[Apache::UploadMeter] Starting upload $hook_data");
	    my $name=$upload->upload_filename;
	    $hook_cache->set($hook_data."name",$name);
	    $hook_cache->set($hook_data."starttime",time());
	}
	$r->log->debug("[Apache::UploadMeter] Updating cache: $hook_data LEN --> $len");
        $hook_cache->set($hook_data."len",$len);
    };
}

### Upload meter generator - Master process
sub u_handler
{
    my $r=shift;
    # Read request
    my $req = APR::Request::Apache2->handle($r);
    my $u_id = $req->args('hook_id') || undef;
    return Apache2::Const::HTTP_BAD_REQUEST unless defined($u_id);
    $r->pnotes("u_id" => $u_id);
    # Initialize cache
    my $hook_cache=new Cache::FileCache(\%cache_options);
    unless ($hook_cache) {
	$r->log_reason("[Apache::UploadMeter] Could not instantiate FileCache.", __FILE__.__LINE__);
        return Apache2::Const::SERVER_ERROR; 
    }
    # Initialize apreq
    $req->upload_hook(hook_handler($r, $u_id));
    my $rsize=$r->headers_in->{"Content-Length"};
    $hook_cache->set($u_id."size",$rsize);
    $r->log->notice("[Apache::UploadMeter] Initialized cache for $u_id");
    return Apache2::Const::DECLINED;
}

### Upload FixupHandler - make sure that uploadsize get's updated to proper size and that size is set to something (Even 0)

sub ufu_handler
{
    my $r=shift;
    # TODO: This is ugly.  We should find a better way to clean up once the
    # upload is complete; probably attaching a clean-up script to something
    # or another...
    # Bettery yet, creating a custom hook that runs once the user calls $req->upload
    my $req = APR::Request::Apache2->handle($r);
    my $u_id=$r->pnotes("u_id");
    my $upload=$req->upload; # Should only return once upload is completed
    my $hook_cache=new Cache::FileCache(\%cache_options);
    unless ($hook_cache) {
	$r->log_reason("[Apache::UploadMeter] Could not instantiate FileCache.", __FILE__.__LINE__);
        return Apache2::Const::DECLINED;
    }
    my $size=$hook_cache->get($u_id."size");
    $hook_cache->set($u_id."len",$size);
    $hook_cache->set($u_id."finished",1);
    return Apache2::Const::OK;
}    

### Upload meter generator - Slave process
sub um_handler
{
    my $r=shift;
    $r->no_cache(1);
    my $req = APR::Request::Apache2->handle($r);
    my $hook_id=$req->param('hook_id') || undef;
    my $initial_request=!($req->param('returned') || 0);
    return Apache2::Const::HTTP_BAD_REQUEST unless defined($hook_id);
    my $hook_cache=new Cache::FileCache(\%cache_options);
    unless ($hook_cache) {
	$r->log_reason("[Apache::UploadMeter] Could not instantiate FileCache.", __FILE__.__LINE__);
        return Apache2::Const::DECLINED;
    }
    my $finished = $hook_cache->get($hook_id."finished") || 0;
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
		$r->log->info("[Apache::UploadMeter] Waiting for upload cache $hook_id to initialize ($i / $TIMEOUT)...");
		sleep 1;
		last if $c->aborted;
	    }
	}
	if ($problem) {
	    $r->custom_response(Apache2::Const::NOT_FOUND, "This upload meter is either invalid, or has expired.");
            return Apache2::Const::NOT_FOUND;
	}
    }
    my $size=$hook_cache->get($hook_id."size") || "Unknown";
    my $fname=$hook_cache->get($hook_id."name") || "Unknown";

    # This is better done in the XSL, I think.  I want to minimize Apache's work here and leave the browser to calculate the stuff.  What I may eventually do is create a second XSL stylesheet which translates the "minimal" formatting into this formatting.  I'm not going to change this first, but it's on my list of things to do - Issac

    # Calculate elapsed and remaining time
    my $currenttime = time();
    my $starttime=$hook_cache->get($hook_id."starttime") || $currenttime;
    my $etime = $currenttime - $starttime;
    my $rtime = ($finished) ? 0 : int ($etime / $len * $size) - $etime;

    # Calculate total rate and current rate
    my $lastupdatetime = $hook_cache->get($hook_id."lastupdatetime");
    my $lastupdatelen = $hook_cache->get($hook_id."lastupdatelen");
    my $currentrate = int (($len - $lastupdatelen) / ($currenttime - $lastupdatetime)) if ($currenttime != $lastupdatetime);
    my $rate = int ($len / ($currenttime - $starttime)) if ($currenttime != $starttime);
    $hook_cache->set($hook_id."lastupdatetime", $currenttime);
    $hook_cache->set($hook_id."lastupdatelen", $len);
    
    # Format values for easy display
    my $fsize = Number::Format::format_bytes($size, 2);
    my $flen = Number::Format::format_bytes($len, 2);
    my $fetime = Date::Format::time2str('%H:%M:%S', $etime, 'GMT');
    my $frtime = Date::Format::time2str('%H:%M:%S', $rtime, 'GMT');
    my $fcurrentrate = Number::Format::format_bytes($currentrate, 2).'/s';
    my $frate = Number::Format::format_bytes($rate, 2).'/s';

    # build the Refresh url
    my $s=$r->server;
    my $name=$s->server_hostname;
    my $args=$r->args;
    if ($initial_request) { $args=$args.(defined($args)?"&":"")."returned=1";}
    if ($finished) {
    	# Cleanup the cache since we are finished
# Not needed.  The hook automatically dumps values every 15 minutes for this reason.  - Issac.  But a purge is probably needed somewhere else for a global scale

        $hook_cache->remove($hook_id."finished");
        $hook_cache->remove($hook_id."len");
        $hook_cache->remove($hook_id."name");
        $hook_cache->remove($hook_id."size");
        $hook_cache->remove($hook_id."starttime");
        $hook_cache->remove($hook_id."lastupdaterate");
        $hook_cache->remove($hook_id."lastupdatelen");
	$hook_cache->clear;
	$hook_cache->purge; #best I can do for now...
    } else {
    	# Set a refresh header so the meter gets updated
        $r->headers_out->add("Refresh"=>"5;url=".($ENV{HTTPS}?"https":"http")."://".$name.':'.$s->port.$r->uri."?".APR::Request::encode($args));
    }
    $r->content_type('text/xml');
    return Apache2::Const::OK if $r->header_only;
    my $xslt=$XSLT;
    my $out= <<EOF;
<?xml version="1.0" encoding="UTF-8"?>
<?xml-stylesheet type="text/xsl" href="$xslt"?>
<APACHE_UPLOADMETER HOOK_ID="$hook_id" FILE="$fname" FINISHED="$finished" xmlns:xsi="http://www.w3.org/2001/XMLSchema-instance" xsi:noNamespaceSchemaLocation="http://apache-umeter.sourceforge.net/apache-umeter-$VERSION.xsd">
    <RECIEVED VALUE="$len">$flen</RECIEVED>
    <TOTAL VALUE="$size">$fsize</TOTAL>
    <ELAPSEDTIME VALUE="$etime">$fetime</ELAPSEDTIME>
    <REMAININGTIME VALUE="$rtime">$frtime</REMAININGTIME>
    <RATE VALUE="$rate">$frate</RATE>
    <CURRENTRATE VALUE="$currentrate">$fcurrentrate</CURRENTRATE>
</APACHE_UPLOADMETER>
EOF

    $r->print($out);
    return Apache2::Const::OK;
}

# Form fixup
sub uf_handler
{
    my $r=shift;
    $r->no_cache(1); # CRITICAL!  No caching allowed!
    my $digest=Digest::SHA1::sha1_hex(time,(defined $r->subprocess_env('HTTP_HOST') ? $r->subprocess_env('HTTP_HOST') : 0),(defined $r->subprocess_env('HTTP_X_FORWARDED_FOR') ?$r->subprocess_env('HTTP_X_FORWARDED_FOR') : 0 ));
    $r->pnotes("u_id"=>$digest);
    return Apache2::Const::OK;
}

### Support handlers (for debugging)

# Simple response handler for displaying upload information
sub r_handler
{
    my $r=shift;
    my $req = APR::Request::Apache2->handle($r);
    $r->no_cache(1);
    my $uploads=$req->upload;
    $r->content_type('text/plain');
    return Apache2::Const::OK if $r->header_only;
    $r->print("Results:\n");
    while (my ($field, $upload) = each %$uploads) {
	$r->print("Parsed upload field $field:\n\tFilename: ".$upload->upload_filename());
	$r->print("\n\tSize: ".$upload->upload_size()."\n\n");
    }
    $r->print("Done\n");
    return Apache2::Const::OK;
}

### Output filters
use base qw(Apache2::Filter);
sub f_uploadform {
    my ($f, $bb) = @_;
    my $bb_ctx = APR::Brigade->new($f->c->pool, $f->c->bucket_alloc);
    unless ($f->ctx) {
        my $handler = $f->r->dir_config("AUM_HANDLER") || undef;
        my $meter = $f->r->dir_config("AUM_METER") || undef;
        my $aum_id = $f->r->dir_config("AUM_ID") || undef;
        
        if (!(defined($handler) && defined($aum_id) && defined($meter))) {
              #&& $srv_cfg->{UploadMeter}->{aum_id}->{UploadForm} eq $uri)) {
            $f->r->log_error("[Apache::UploadMeter] No configuration data found for this UploadMeter");
            $f->remove;
            return Apache2::Const::DECLINED;
        }
	my $u_id=$f->r->pnotes('u_id') || undef;
	if (!(defined($u_id))) {
	    ### FIX THE ERROR
	    $f->r->log_error("[Apache::UploadMeter] No u_id in pnotes table. Make sure you ran configure()");
	    $f->remove; # We can't do anything useful anymore
            return Apache2::Const::DECLINED;
	}
        $f->r->log->debug("[Apache::UploadMeter] Initialized $aum_id with instance $u_id");
	my $output=<<"EOF";
<script type="text/javascript">
// <![CDATA[
function openUploadMeter()
{
    uploadWindow=window.open(\"${meter}?hook_id=${u_id}\",\"_new\",\"toolbar=no,location=no,directories=no,status=yes,menubar=no,scrollbars=no,resizeable=no,width=450,height=240\");
}
// ]]>
</script>
<noscript>You must use a JavaScript-enabled browser to use this page properly</noscript>
<form action=\"${handler}?hook_id=${u_id}\" method=\"post\" enctype=\"multipart/form-data\" onSubmit=\"openUploadMeter()\">
EOF

	$f->ctx({leftover => undef, output => $output});
    }
  
    while (!$bb->is_empty) {
        my $b = $bb->first;
        $f->r->log->debug($b->type->name);
        $b->remove;
        
        if ($b->is_eos) {            
            if (defined(${$f->ctx}{leftover})) {
                $bb_ctx->insert_tail(APR::Bucket->new($bb_ctx->bucket_alloc, ${$f->ctx}{leftover}));
            }
            $bb_ctx->insert_tail($b);
            last;
        } elsif ($b->read(my $buf)) {
            my $outbuf = "";
            # We need an output buffer, since we can't copy string data going into buckets
            
            $buf = ${$f->ctx}{leftover}.$buf if defined(${$f->ctx}{leftover});
            while ($buf=~/^(.*?)(<.*?>)(.*)/ms) {
                my ($pre,$tag) = (gensym(), gensym());
                ($pre,$tag,$buf) = ($1,$2,$3);
                $outbuf.=$pre;
                $f->r->log->debug($tag. ":" . $buf);
                if ($tag=~/\<\!--\s*?#uploadform\s*?--\>/i) {
                    $tag = ${$f->ctx}{output};
                }                
                $outbuf.=$tag;
            }
            $bb_ctx->insert_tail(APR::Bucket->new($bb_ctx->bucket_alloc, $outbuf));

            ${$f->ctx}{leftover} = $buf || undef;
        } else {
            $bb_ctx->insert_tail($b);
        }
    }
    
    my $rv = $f->next->pass_brigade($bb_ctx);
    return $rv unless $rv == APR::Const::SUCCESS;
    return Apache2::Const::OK;
}



# Input filters
# We use a null input filter (placed after apreq) to detect finished requests

sub upload_jit_handler($)
{
    my $r=shift;
    $r->push_handlers("PerlFixupHandler",\&ufu_handler);
    #$r->push_handlers("PerlHandler",\&r_handler);
    #$r->handler("perl-script");
    return u_handler($r);
}

sub meter_jit_handler($)
{
    my $r=shift;
    $r->handler("perl-script");
    $r->push_handlers("PerlHandler",\&um_handler);
    return Apache2::Const::DECLINED;
}
 
sub form_jit_handler($)
{
    my $r=shift;
    $r->push_handlers("PerlFixupHandler",\&uf_handler);
    $r->add_output_filter(\&f_uploadform);
    return Apache2::Const::DECLINED;
}

my @directives = (
    {
        name            => "<UploadMeter",
        func            => __PACKAGE__ . "::configure",
        req_override    => Apache2::Const::OR_ALL,
        args_how        => Apache2::Const::RAW_ARGS,
        errmsg          => "Container to define an Apache::UploadMeter instance.",
    }, {
        name            => "</UploadMeter",
        func            => __PACKAGE__ . "::configure_end",
        req_override    => Apache2::Const::OR_ALL,
        args_how        => Apache2::Const::RAW_ARGS,
    }, {
        name            => "UploadMeter",
        func            => __PACKAGE__ . "::configure_invalid",
        req_override    => Apache2::Const::OR_ALL,
        args_how        => Apache2::Const::RAW_ARGS,
        cmd_data        => "UploadMeter",
    }, {
        name            => "UploadHandler",
        func            => __PACKAGE__ . "::configure_invalid",
        req_override    => Apache2::Const::OR_ALL,
        args_how        => Apache2::Const::RAW_ARGS,
        cmd_data        => "UploadHandler",
    }, {
        name            => "UploadForm",
        func            => __PACKAGE__ . "::configure_invalid",
        req_override    => Apache2::Const::OR_ALL,
        args_how        => Apache2::Const::RAW_ARGS,
        cmd_data        => "UploadForm",
    },
);

Apache2::Module::add(__PACKAGE__, \@directives);

sub configure
{
    my ($self, $parms, $val) = @_;
    my $namespace=__PACKAGE__;
    $val =~s/^(.*)>$/$1/; # Clean trailing ">"
    if (my $error = $parms->check_cmd_context(Apache2::Const::NOT_IN_LIMIT |
                                              Apache2::Const::NOT_IN_DIR_LOC_FILE)) {
        die $error;
    }
    #Ignore <UploadMeter xxx> directive
    my $dir = $parms->directive->as_hash->{"UploadMeter"}->{$val};
    my $tmp = {};
    # Verify that we have our directives and get rid of other junk
    map {
        if (!(defined($dir->{$_}))) {
            die "Missing mandatory $_ parameter";
        }
        $tmp->{$_} = $dir->{$_};
    } qw(UploadMeter UploadHandler UploadForm);
    # TODO: Fix this and use it to retrieve config vars elsewhere.
    # We cheat nowadays
    my $srv_cfg = $self->{UploadMeter};
    $srv_cfg->{$val}=$tmp;
    $self->{UploadMeter} = $srv_cfg;
    my ($UH, $UF, $UM) = ($tmp->{UploadHandler},
                          $tmp->{UploadForm},
                          $tmp->{UploadMeter});
    my $config = <<"EOC";
<Location $UH>
    Options +ExecCGI
    PerlInitHandler Apache::UploadMeter::upload_jit_handler
    PerlSetVar AUM_ID $val
</Location>
<Location $UF>
    Options +ExecCGI
    PerlInitHandler Apache::UploadMeter::form_jit_handler
    PerlSetVar AUM_ID $val
    PerlSetVar AUM_HANDLER $UH
    PerlSetVar AUM_METER $UM
</Location>
<Location $UM>
    Options +ExecCGI
    PerlInitHandler Apache::UploadMeter::meter_jit_handler
    PerlSetVar AUM_ID $val
</Location>
EOC

    $parms->server->add_config([split /\n/, $config]);
    $parms->server->log->info("Configured $namespace v$VERSION \"$val\" $UH - $UM - $UF");
}

sub configure_invalid {
    my ($self, $parms, $val) = @_;
    my $conf = $parms->info;
    die "Error: $conf must appear inside an <UploadMeter> container";
}

sub configure_end {
    my ($self, $parms, $val) = @_;
    my $conf = $parms->info;
    die "Error: </UploadMeter> without opening <UploadMeter>";
}

1;
__END__

=head1 NAME

Apache::UploadMeter - Apache module which implements an upload meter for form-based uploads

=head1 SYNOPSIS

  (in httpd.conf)
  PerlLoadModule Apache::UploadMeter
  
  <UploadMeter MyUploadMeter>
      UploadForm    /form.html
      UploadHandler /perl/upload
      UploadMeter   /perl/meter
  </UploadMeter>

  (in /form.html)

  <!--#uploadform-->
  <INPUT TYPE="FILE" NAME="theFile"/>
  <INPUT TYPE="SUBMIT"/>
  </FORM>

=head1 DESCRIPTION

Apache::UploadMeter is a mod_perl module which implements a status-meter/progress-bar
to show realtime progress of uploads done using a form with enctype=multipart/formdata.

The only changes needed to be made to existing pages and/or scripts is the replacement
of the existing E<lt>FORME<gt> tag, which is done automatically the a special directive
E<lt>!--#uploadform--E<gt> instead of the existing E<lt>FORME<gt> tag.

NOTE: To use this module, mod_perl MUST be built with StackedHandlers enabled.

=head1 CONFIGURATION

Configuration is done in httpd.conf using <UploadMeter> sections which contain
the URLs needed to manipulate each meter.  Currently multiple meters are supported
with the drawback that they must use distinct URLs (eg, you can't have 2 meters
with the same UploadMeter path).

=over

=item *

E<lt>UploadMeter I<MyMeter>E<gt>
Defines a new UploadMeter.  The I<MyMeter> parameter specifies a unique name
for this uploadmeter.  Currently, names are required and must be unique.

In a future version, if no name is given, a unique symbol will be generated
for the meter.

Each UploadMeter section requires 3 sub-parameters

=over

=item *
UploadForm

This should point to the URI on the server which contains the upload form with
the special E<lt>!--#uploadform--E<gt> tag.  Note that there should NOT be an
opening E<lt>FORME<gt> tag, but there SHOULD be a closing E<lt>/FORME<gt>
tag on the HTML page.

=item *

UploadHandler

This should point to the target (eg, ACTION) of the upload form.  The target
should already exist and do something useful.

=item *

UploadMeter

This should point to an unused URI on the server. This URI will be used to
provide the progress-meter window.

=back

=back

=head1 COMPATIBILITY

Beginning from version 0.99_01, this module is only compatible with
Apache2/mod_perl2 Support for Apache 1.3.x is discontinued, as it's too damn
complicated to configure in Apache 1.3.x  This may change in the future, but I
doubt it; servers are slowly but surely migrating from 1.3 to 2.x  Maybe it's
finally time for you to upgrade too.

=head1 AUTHOR AND COPYRIGHT

Copyright (c) 2001-2007 Issac Goldstand E<lt>margol@beamartyr.netE<gt> - All rights reserved.

This library is free software. It can be redistributed and/or modified
under the same terms as Perl itself.

=head1 SEE ALSO

Apache2::Request(3)

=cut
