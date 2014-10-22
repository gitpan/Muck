#  This software code is made available "AS IS" without warranties of any
#  kind.  You may copy, display, modify and redistribute the software
#  code either by itself or as incorporated into your code; provided that
#  you do not remove any proprietary notices.  Your use of this software
#  code is at your own risk and you waive any claim against Amazon
#  Digital Services, Inc. or its affiliates with respect to your use of
#  this software code. (c) 2006 Amazon Digital Services, Inc. or its
#  affiliates.

package Muck::FS::S3::AWSAuthConnection;

use strict;
use warnings;

use HTTP::Date;
use URI::Escape;
use Carp;

use Muck::FS::S3 qw($DEFAULT_HOST $PORTS_BY_SECURITY merge_meta urlencode);
use Muck::FS::S3::GetResponse;
use Muck::FS::S3::ListBucketResponse;
use Muck::FS::S3::ListAllMyBucketsResponse;
use Muck::FS::S3::S3Object;

sub new {
    my $proto = shift;
    my $class = ref($proto) || $proto;
    my $self  = {};
    $self->{AWS_ACCESS_KEY_ID} = shift || croak "must specify aws access key id";
    $self->{AWS_SECRET_ACCESS_KEY} = shift || croak "must specify aws secret access key";
    $self->{IS_SECURE} = shift;
    $self->{IS_SECURE} = 1 if (not defined $self->{IS_SECURE});
    $self->{SERVER} = shift || $DEFAULT_HOST;
    $self->{PORT} = shift || $PORTS_BY_SECURITY->{$self->{IS_SECURE}};
    $self->{AGENT} = LWP::UserAgent->new();
    bless ($self, $class);
    return $self;
}

sub create_bucket {
    my ($self, $bucket, $headers) = @_;
    croak 'must specify bucket' unless $bucket;
    $headers ||= {};

    return Muck::FS::S3::Response->new($self->_make_request('PUT', $bucket, $headers));
}

sub list_bucket {
    my ($self, $bucket, $options, $headers) = @_;
    croak 'must specify bucket' unless $bucket;
    $options ||= {};
    $headers ||= {};

    my $path = $bucket;
    if (%$options) {
        $path .= "?" . join('&', map { "$_=" . urlencode($options->{$_}) } keys %$options)
    }

    return Muck::FS::S3::ListBucketResponse->new($self->_make_request('GET', $path, $headers));
}

sub delete_bucket {
    my ($self, $bucket, $headers) = @_;
    croak 'must specify bucket' unless $bucket;
    $headers ||= {};

    return Muck::FS::S3::Response->new($self->_make_request('DELETE', $bucket, $headers));
}

sub put {
    my ($self, $bucket, $key, $object, $headers) = @_;
    croak 'must specify bucket' unless $bucket;
    croak 'must specify key' unless $key;
    $headers ||= {};

    $key = urlencode($key);

    if (ref($object) ne 'Muck::FS::S3::S3Object') {
        $object = Muck::FS::S3::S3Object->new($object);
    }

    return Muck::FS::S3::Response->new($self->_make_request('PUT', "$bucket/$key", $headers, $object->data, $object->metadata));
}

sub get {
    my ($self, $bucket, $key, $headers) = @_;
    croak 'must specify bucket' unless $bucket;
    croak 'must specify key' unless $key;
    $headers ||= {};

    $key = urlencode($key);

    return Muck::FS::S3::GetResponse->new($self->_make_request('GET', "$bucket/$key", $headers));
}

sub delete {
    my ($self, $bucket, $key, $headers) = @_;
    croak 'must specify bucket' unless $bucket;
    croak 'must specify key' unless $key;
    $headers ||= {};

    $key = urlencode($key);

    return Muck::FS::S3::Response->new($self->_make_request('DELETE', "$bucket/$key", $headers));
}

sub get_bucket_logging {
    my ($self, $bucket, $headers) = @_;
    croak 'must specify bucket' unless $bucket;
    return Muck::FS::S3::GetResponse->new($self->_make_request('GET', "$bucket?logging", $headers));
}

sub put_bucket_logging {
    my ($self, $bucket, $logging_xml_doc, $headers) = @_;
    croak 'must specify bucket' unless $bucket;
    return Muck::FS::S3::Response->new($self->_make_request('PUT', "$bucket?logging", $headers, $logging_xml_doc));
}

sub get_bucket_acl {
    my ($self, $bucket, $headers) = @_;
    croak 'must specify bucket' unless $bucket;
    return $self->get_acl($bucket, "", $headers);
}

sub get_acl {
    my ($self, $bucket, $key, $headers) = @_;
    croak 'must specify bucket' unless $bucket;
    croak 'must specify key' unless defined $key;
    $headers ||= {};

    $key = urlencode($key);

    return Muck::FS::S3::GetResponse->new($self->_make_request('GET', "$bucket/$key?acl", $headers));
}

sub put_bucket_acl {
    my ($self, $bucket, $acl_xml_doc, $headers) = @_;
    return $self->put_acl($bucket, '', $acl_xml_doc, $headers);
}

sub put_acl {
    my ($self, $bucket, $key, $acl_xml_doc, $headers) = @_;
    croak 'must specify acl xml document' unless defined $acl_xml_doc;
    croak 'must specify bucket' unless $bucket;
    croak 'must specify key' unless defined $key;
    $headers ||= {};

    $key = urlencode($key);

    return Muck::FS::S3::Response->new(
        $self->_make_request('PUT', "$bucket/$key?acl", $headers, $acl_xml_doc));
}

sub list_all_my_buckets {
    my ($self, $headers) = @_;
    $headers ||= {};

    return Muck::FS::S3::ListAllMyBucketsResponse->new($self->_make_request('GET', '', $headers));
}

sub _make_request {
    my ($self, $method, $path, $headers, $data, $metadata) = @_;
    croak 'must specify method' unless $method;
    croak 'must specify path' unless defined $path;
    $headers ||= {};
    $data ||= '';
    $metadata ||= {};

    my $http_headers = merge_meta($headers, $metadata);

    $self->_add_auth_header($http_headers, $method, $path);
    my $protocol = $self->{IS_SECURE} ? 'https' : 'http';
    my $url = "$protocol://$self->{SERVER}:$self->{PORT}/$path";
    my $request = HTTP::Request->new($method, $url, $http_headers);
    $request->content($data);
    return $self->{AGENT}->request($request);
}

sub _add_auth_header {
    my ($self, $headers, $method, $path) = @_;

    if (not $headers->header('Date')) {
        $headers->header(Date => time2str(time));
    }
    my $canonical_string = Muck::FS::S3::canonical_string($method, $path, $headers);
    my $encoded_canonical = Muck::FS::S3::encode($self->{AWS_SECRET_ACCESS_KEY}, $canonical_string);
    $headers->header(Authorization => "AWS $self->{AWS_ACCESS_KEY_ID}:$encoded_canonical");
}

1;
