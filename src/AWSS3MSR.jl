#==============================================================================#
# AWSS3.jl
#
# S3 API. See http://docs.aws.amazon.com/AmazonS3/latest/API/APIRest.html
#
# Copyright OC Technology Pty Ltd 2014 - All rights reserved
#==============================================================================#


__precompile__()


module AWSS3MSR

export s3_arn, s3_put, s3_get, s3_get_file, s3_exists, s3_delete, s3_copy,
       s3_create_bucket,
       s3_put_cors,
       s3_enable_versioning, s3_delete_bucket, s3_list_buckets,
       s3_list_objects, s3_list_keys, s3_list_versions,
       s3_get_meta, s3_purge_versions,
       s3_sign_url, s3_begin_multipart_upload, s3_upload_part,
       s3_complete_multipart_upload, s3_multipart_upload,
       s3_get_tags, s3_put_tags, s3_delete_tags

import HttpCommon: Response
import Requests: mimetype
import DataStructures: OrderedDict

using AWSCoreMSR
using SymDict
using Retry
using XMLDict
using LightXML
using URIParser

import Requests: format_query_str

const SSDict = Dict{String,String}


"""
    s3_arn(resource)
    s3_arn(bucket,path)

[Amazon Resource Name](http://docs.aws.amazon.com/general/latest/gr/aws-arns-and-namespaces.html)
for S3 `resource` or `bucket` and `path`.
"""
s3_arn(resource) = "arn:aws:s3:::$resource"
s3_arn(bucket, path) = s3_arn("$bucket/$path")


# S3 REST API request.

function s3(aws::AWSConfig,
            verb,
            bucket="";
            headers=SSDict(),
            path="",
            query=SSDict(),
            version="",
            content="",
            return_stream=false,
            return_raw=false,)

    # Build query string...
    if version != ""
        query["versionId"] = version
    end
    query_str = format_query_str(query)

    # Build URL...
    resource = string("/", AWSCoreMSR.escape_path(path),
                      query_str == "" ? "" : "?$query_str")
    url = string(aws_endpoint("s3", "", bucket), resource)

    # Build Request...
    request = @SymDict(service = "s3",
                       verb,
                       url,
                       resource,
                       headers,
                       content,
                       return_stream,
                       return_raw,
                       aws...)

    @repeat 3 try

        # Check bucket region cache...
        try request[:region] = aws[:bucket_region][bucket] end
        return AWSCoreMSR.do_request(request)

    catch e

        # Update bucket region cache if needed...
        @retry if typeof(e) == AWSCoreMSR.AuthorizationHeaderMalformed &&
                  haskey(e.info, "Region")

            if AWSCoreMSR.debug_level > 0
                println("S3 region redirect $bucket -> $(e.info["Region"])")
            end
            if !haskey(aws, :bucket_region)
                aws[:bucket_region] = SSDict()
            end
            aws[:bucket_region][bucket] = e.info["Region"]
        end
    end

    assert(false) # Unreachable.
end


"""
    s3_get([::AWSConfig], bucket, path; <keyword arguments>)

[Get Object](http://docs.aws.amazon.com/AmazonS3/latest/API/RESTObjectGET.html)
from `path` in `bucket`.

# Optional Arguments
- `version=`: version of object to get.
- `retry=true`: try again on "NoSuchBucket", "NoSuchKey"
                (common if object was recently created).
- `raw=false`:  return response as `Vector{UInt8}`
                (by default return type depends on `Content-Type` header).
"""

function s3_get(aws::AWSConfig, bucket, path; version="",
                                              retry=true,
                                              raw=false)

    @repeat 4 try

        return s3(aws, "GET", bucket; path = path,
                                      version = version,
                                      return_raw = raw)

    catch e
        @delay_retry if retry && e.code in ["NoSuchBucket", "NoSuchKey"] end
    end
end

s3_get(a...; b...) = s3_get(default_aws_config(), a...; b...)


"""
    s3_get_file([::AWSConfig], bucket, path, filename; [version=])

Like `s3_get` but streams result directly to `filename`.
"""
function s3_get_file(aws::AWSConfig, bucket, path, filename; version="")

    stream = s3(aws, "GET", bucket; path = path,
                                    version = version,
                                    return_stream = true)

    try
        open(filename, "w") do file
            while !eof(stream)
                write(file, readavailable(stream))
            end
        end
    finally
        close(stream)
    end
end

s3_get_file(a...; b...) = s3_get_file(default_aws_config(), a...; b...)


function s3_get_file(aws::AWSConfig, buckets::Vector, path, filename; version="")

    i = start(buckets)

    @repeat length(buckets) try

        bucket, i = next(buckets, i)
        s3_get_file(aws, bucket, path, filename; version=version);

    catch e
        @retry if e.code in ["NoSuchKey", "AccessDenied"] end
    end
end


"""
   s3_get_meta([::AWSConfig], bucket, path; [version=])

[HEAD Object](http://docs.aws.amazon.com/AmazonS3/latest/API/RESTObjectHEAD.html)

Retrieves metadata from an object without returning the object itself.
"""
function s3_get_meta(aws::AWSConfig, bucket, path; version="")

    res = s3(aws, "HEAD", bucket; path = path, version = version)
    return res.headers
end

s3_get_meta(a...; b...) = s3_get_meta(default_aws_config(), a...; b...)


"""
    s3_exists([::AWSConfig], bucket, path [version=])

Is there an object in `bucket` at `path`?
"""
function s3_exists(aws::AWSConfig, bucket, path; version="")

    @repeat 2 try

        s3_get_meta(aws, bucket, path; version = version)

        return true

    catch e
        @delay_retry if e.code in ["NoSuchBucket", "404",
                                   "NoSuchKey", "AccessDenied"]
        end
        @ignore if e.code in ["404", "NoSuchKey", "AccessDenied"]
            return false
        end
    end
end

s3_exists(a...; b...) = s3_exists(default_aws_config(), a...; b...)


"""
    s3_delete([::AWSConfig], bucket, path; [version=]

[DELETE Object](http://docs.aws.amazon.com/AmazonS3/latest/API/RESTObjectDELETE.html)
"""
function s3_delete(aws::AWSConfig, bucket, path; version="")

    s3(aws, "DELETE", bucket; path = path, version = version)
end

s3_delete(a...; b...) = s3_delete(default_aws_config(), a...; b...)


"""
    s3_copy([::AWSConfig], bucket, path; to_bucket=bucket, to_path=path)

[PUT Object - Copy](http://docs.aws.amazon.com/AmazonS3/latest/API/RESTObjectCOPY.html)

# Optional Arguments
- `metadata::Dict=`; optional `x-amz-meta-` headers.
"""
function s3_copy(aws::AWSConfig, bucket, path;
                 to_bucket=bucket, to_path=path, metadata::SSDict = SSDict())

    headers = SSDict("x-amz-copy-source" => "/$bucket/$path",
                     "x-amz-metadata-directive" => "REPLACE",
                     Pair["x-amz-meta-$k" => v for (k, v) in metadata]...)

    s3(aws, "PUT", to_bucket; path = to_path, headers = headers)
end

s3_copy(a...; b...) = s3_copy(default_aws_config(), a...; b...)


"""
    s3_create_bucket([:AWSConfig], bucket)

[PUT Bucket](http://docs.aws.amazon.com/AmazonS3/latest/API/RESTBucketPUT.html)
"""

function s3_create_bucket(aws::AWSConfig, bucket)

    println("""Creating Bucket "$bucket"...""")

    @protected try

        if aws[:region] == "us-east-1"

            s3(aws, "PUT", bucket)

        else

            s3(aws, "PUT", bucket;
                headers = SSDict("Content-Type" => "text/plain"),
                content = """
                <CreateBucketConfiguration
                             xmlns="http://s3.amazonaws.com/doc/2006-03-01/">
                    <LocationConstraint>$(aws[:region])</LocationConstraint>
                </CreateBucketConfiguration>""")
        end

    catch e
        @ignore if e.code == "BucketAlreadyOwnedByYou" end
    end
end

s3_create_bucket(a) = s3_create_bucket(default_aws_config(), a)


"""
    s3_put_cors([::AWSConfig], bucket, cors_config)

[PUT Bucket cors](http://docs.aws.amazon.com/AmazonS3/latest/API/RESTBucketPUTcors.html)

```
s3_put_cors("my_bucket", \"\"\"
    <?xml version="1.0" encoding="UTF-8"?>
    <CORSConfiguration xmlns="http://s3.amazonaws.com/doc/2006-03-01/">
        <CORSRule>
            <AllowedOrigin>http://my.domain.com</AllowedOrigin>
            <AllowedOrigin>http://my.other.domain.com</AllowedOrigin>
            <AllowedMethod>GET</AllowedMethod>
            <AllowedMethod>HEAD</AllowedMethod>
            <AllowedHeader>*</AllowedHeader>
            <ExposeHeader>Content-Range</ExposeHeader>
        </CORSRule>
    </CORSConfiguration>
\"\"\"
```
"""

function s3_put_cors(aws::AWSConfig, bucket, cors_config)
    s3(aws, "PUT", bucket, path = "?cors", content = cors_config)
end

s3_put_cors(a...) = s3_put_cors(default_aws_config(), a...)


"""
    s3_enable_versioning([::AWSConfig], bucket)

[Enable versioning for `bucket`](http://docs.aws.amazon.com/AmazonS3/latest/API/RESTBucketPUTVersioningStatus.html).
"""

function s3_enable_versioning(aws::AWSConfig, bucket)

    s3(aws, "PUT", bucket;
       query = SSDict("versioning" => ""),
       content = """
       <VersioningConfiguration xmlns="http://s3.amazonaws.com/doc/2006-03-01/">
           <Status>Enabled</Status>
       </VersioningConfiguration>""")
end

s3_enable_versioning(a) = s3_enable_versioning(default_aws_config(), a)


"""
    s3_put_tags([::AWSConfig], bucket, [path,] tags::Dict)

PUT `tags` on
[`bucket`](http://docs.aws.amazon.com/AmazonS3/latest/API/RESTBucketPUTtagging.html)
or
[object (`path`)](http://docs.aws.amazon.com/AmazonS3/latest/API/RESTObjectPUTtagging.html).

See also `tags=` option on [`s3_put`](@ref).
"""

function s3_put_tags(aws::AWSConfig, bucket, tags::SSDict)
    s3_put_tags(aws, bucket, "", tags)
end


function s3_put_tags(aws::AWSConfig, bucket, path, tags::SSDict)

    tags = Dict("Tagging" =>
           Dict("TagSet" =>
           Dict("Tag" =>
           [Dict("Key" => k, "Value" => v) for (k,v) in tags])))

    s3(aws, "PUT", bucket;
       path = path,
       query = SSDict("tagging" => ""),
       content = XMLDict.node_xml(tags))
end

s3_put_tags(a...) = s3_put_tags(default_aws_config(), a...)


"""
    s3_get_tags([::AWSConfig], bucket, [path])

Get tags from
[`bucket`](http://docs.aws.amazon.com/AmazonS3/latest/API/RESTBucketGETtagging.html)
or
[object (`path`)](http://docs.aws.amazon.com/AmazonS3/latest/API/RESTObjectGETtagging.html).
"""

function s3_get_tags(aws::AWSConfig, bucket, path="")

    @protected try

        tags = s3(aws, "GET", bucket; path = path, query = SSDict("tagging" => ""))
        if isempty(tags["TagSet"])
            return SSDict()
        end
        tags = tags["TagSet"]
        tags = isa(tags["Tag"], Vector) ? tags["Tag"] : [tags["Tag"]]

        return SSDict(x["Key"] => x["Value"] for x in tags)

    catch e
        @ignore if e.code == "NoSuchTagSet"
            return SSDict()
        end
    end
end

s3_get_tags(a...) = s3_get_tags(default_aws_config(), a...)


"""
    s3_delete_tags([::AWSConfig], bucket, [path])

Delete tags from
[`bucket`](http://docs.aws.amazon.com/AmazonS3/latest/API/RESTBucketDELETEtagging.html)
or
[object (`path`)](http://docs.aws.amazon.com/AmazonS3/latest/API/RESTObjectDELETEtagging.html).
"""

function s3_delete_tags(aws::AWSConfig, bucket, path="")
    s3(aws, "DELETE", bucket; path = path, query = SSDict("tagging" => ""))
end

s3_delete_tags(a...) = s3_delete_tags(default_aws_config(), a...)


"""
    s3_delete_bucket([::AWSConfig], "bucket")

[DELETE Bucket](http://docs.aws.amazon.com/AmazonS3/latest/API/RESTBucketDELETE.html).
"""

s3_delete_bucket(aws::AWSConfig, bucket) = s3(aws, "DELETE", bucket)

s3_delete_bucket(a) = s3_delete_bucket(default_aws_config(), a)


"""
    s3_list_buckets([::AWSConfig])

[List of all buckets owned by the sender of the request](http://docs.aws.amazon.com/AmazonS3/latest/API/RESTServiceGET.html).
"""
function s3_list_buckets(aws::AWSConfig = default_aws_config())

    r = s3(aws,"GET", headers=SSDict("Content-Type" => "application/json"))
    buckets = r["Buckets"]["Bucket"]
    [b["Name"] for b in (isa(buckets, Vector) ? buckets : [buckets])]
end


"""
    s3_list_objects([::AWSConfig], bucket, [path_prefix])

[List Objects](http://docs.aws.amazon.com/AmazonS3/latest/API/RESTBucketGET.html)
in `bucket` with optional `path_prefix`.

Returns `Vector{Dict}` with keys `Key`, `LastModified`, `ETag`, `Size`,
`Owner`, `StorageClass`.
"""

function s3_list_objects(aws::AWSConfig, bucket, path_prefix="")

    more = true
    objects = []
    marker = ""

    while more

        q = SSDict()
        if path_prefix != ""
            q["delimiter"] = "/"
            q["prefix"] = path_prefix
        end
        if marker != ""
            q["marker"] = marker
        end

        @repeat 4 try

            r = s3(aws, "GET", bucket; query = q)

            more = r["IsTruncated"] == "true"
            # FIXME return an iterator to allow streaming of truncated results!

            if haskey(r, "Contents")
                l = isa(r["Contents"], Vector) ? r["Contents"] : [r["Contents"]]
                for object in l
                    push!(objects, xml_dict(object))
                    marker = object["Key"]
                end
            end

        catch e
            @delay_retry if e.code in ["NoSuchBucket"] end
        end
    end

    return objects
end

s3_list_objects(a...) = s3_list_objects(default_aws_config(), a...)


"""
    s3_list_keys([::AWSConfig], bucket, [path_prefix])

Like [`s3_list_objects`](@ref) but returns object keys as `Vector{String}`.
"""

function s3_list_keys(aws::AWSConfig, bucket, path_prefix="")

    (o["Key"] for o in s3_list_objects(aws::AWSConfig, bucket, path_prefix))
end

s3_list_keys(a...) = s3_list_keys(default_aws_config(), a...)



"""
    s3_list_versions([::AWSConfig], bucket, [path_prefix])

[List object versions](http://docs.aws.amazon.com/AmazonS3/latest/API/RESTBucketGETVersion.html) in `bucket` with optional `path_prefix`.
"""

function s3_list_versions(aws::AWSConfig, bucket, path_prefix="")

    more = true
    versions = []
    marker = ""

    while more

        query = SSDict("versions" => "", "prefix" => path_prefix)
        if marker != ""
            query["key-marker"] = marker
        end

        r = s3(aws, "GET", bucket; query = query)
        more = r["IsTruncated"][1] == "true"
        for e in child_elements(root(r.x))
            if name(e) in ["Version", "DeleteMarker"]
                version = xml_dict(e)
                version["state"] = name(e)
                push!(versions, version)
                marker = version["Key"]
            end
        end
    end
    return versions
end

s3_list_versions(a...) = s3_list_versions(default_aws_config(), a...)


import Base.ismatch
ismatchMSR(pattern::AbstractString, s::AbstractString) = ismatch(Regex(pattern), s)


"""
    s3_purge_versions([::AWSConfig], bucket, [path [, pattern]])

[DELETE](http://docs.aws.amazon.com/AmazonS3/latest/API/RESTObjectDELETE.html)
all object versions except for the latest version.
"""
function s3_purge_versions(aws::AWSConfig, bucket, path="", pattern="")

    for v in s3_list_versions(aws, bucket, path)
        if pattern == "" || ismatch(pattern, v["Key"])
            if v["IsLatest"] != "true"
                s3_delete(aws, bucket, v["Key"]; version = v["VersionId"])
            end
        end
    end
end

s3_purge_versions(a...) = s3_purge_versions(default_aws_config(), a...)

"""
    s3_put([::AWSConfig], bucket, path, data; <keyword arguments>

[PUT Object](http://docs.aws.amazon.com/AmazonS3/latest/API/RESTObjectPUT.html)
`data` at `path` in `bucket`.

# Optional Arguments
- `data_type=`; `Content-Type` header.
- `encoding=`; `Content-Encoding` header.
- `metadata::Dict=`; `x-amz-meta-` headers.
- `tags::Dict=`; `x-amz-tagging-` headers
                 (see also [`s3_put_tags`](@ref) and [`s3_get_tags`](@ref)).
"""

function s3_put(aws::AWSConfig,
                bucket, path, data::Union{String,Vector{UInt8}},
                data_type="", encoding="";
                metadata::SSDict = SSDict(),
                tags::SSDict = SSDict())

    if data_type == ""
        data_type = "application/octet-stream"
        for (e, t) in [
            (".pdf",  "application/pdf"),
            (".csv",  "text/csv"),
            (".txt",  "text/plain"),
            (".log",  "text/plain"),
            (".dat",  "application/octet-stream"),
            (".gz",   "application/octet-stream"),
            (".bz2",  "application/octet-stream"),
        ]
            if ismatch(e * "\$", path)
                data_type = t
                break
            end
        end
    end

    headers = SSDict("Content-Type" => data_type,
                     Pair["x-amz-meta-$k" => v for (k, v) in metadata]...)

    if !isempty(tags)
        headers["x-amz-tagging"] = format_query_str(tags)
    end

    if encoding != ""
        headers["Content-Encoding"] = encoding
    end

    s3(aws, "PUT", bucket;
       path = path,
       headers = headers,
       content = data)
end

s3_put(a...; b...) = s3_put(default_aws_config(), a...; b...)


function s3_begin_multipart_upload(aws::AWSConfig,
                                   bucket, path,
                                   data_type = "application/octet-stream")

    s3(aws, "POST", bucket; path=path, query = SSDict("uploads"=>""))
end


function s3_upload_part(aws::AWSConfig, upload, part_number, part_data)

    response = s3(aws, "PUT", upload["Bucket"];
                  path = upload["Key"],
                  query = Dict("partNumber" => part_number,
                               "uploadId" => upload["UploadId"]),
                  content = part_data)

    response.headers["ETag"]
end


function s3_complete_multipart_upload(aws::AWSConfig,
                                      upload, parts::Vector{String})
    doc = XMLDocument()
    root = create_root(doc, "CompleteMultipartUpload")

    for (i, etag) in enumerate(parts)

        xchild = new_child(root, "Part")
        xpartnumber = new_child(xchild, "PartNumber")
        xetag = new_child(xchild, "ETag")
        add_text(xpartnumber, string(i))
        add_text(xetag, etag)
    end

    response = s3(aws, "POST", upload["Bucket"];
                  path = upload["Key"],
                  query = Dict("uploadId" => upload["UploadId"]),
                  content = string(doc))
    free(doc)

    response
end


function s3_multipart_upload(aws::AWSConfig, bucket, path, io::IOStream,
                             part_size_mb = 50)

    part_size = part_size_mb * 1024 * 1024

    upload = s3_begin_multipart_upload(aws, bucket, path)

    tags = Vector{String}()
    buf = Vector{UInt8}(part_size)

    i = 0
    while (n = readbytes!(io, buf, part_size)) > 0
        if n < part_size
            resize!(buf, n)
        end
        push!(tags, s3_upload_part(aws, upload, (i += 1), buf))
    end

    s3_complete_multipart_upload(aws, upload, tags)
end


using MbedTLS


"""
    s3_sign_url([::AWSConfig], bucket, path, [seconds=3600];
                [verb="GET"], [content_type="application/octet-stream"])

Create a
[pre-signed url](http://docs.aws.amazon.com/AmazonS3/latest/dev/ShareObjectPreSignedURL.html) for `bucket` and `path` (expires after for `seconds`).

To create an upload URL use `verb="PUT"` and set `content_type` to match
the type used in the `Content-Type` header of the PUT request.

```
url = s3_sign_url("my_bucket", "my_file.txt"; verb="PUT")
Requests.put(URI(url), "Hello!")
```
```
url = s3_sign_url("my_bucket", "my_file.txt";
                  verb="PUT", content_type="text/plain")

Requests.put(URI(url), "Hello!";
             headers=Dict("Content-Type" => "text/plain"))
```
"""
function s3_sign_url(aws::AWSConfig, bucket, path, seconds=3600;
                     verb="GET", content_type="application/octet-stream")

    path = AWSCore.escape_path(path)

    expires = round(Int, Dates.datetime2unix(now(Dates.UTC)) + seconds)

    query = SSDict("AWSAccessKeyId" =>  aws[:creds].access_key_id,
                   "x-amz-security-token" => get(aws, "token", ""),
                   "Expires" => string(expires),
                   "response-content-disposition" => "attachment")

    if verb != "PUT"
        content_type = ""
    end

    to_sign = "$verb\n\n$content_type\n$(query["Expires"])\n" *
              "x-amz-security-token:$(query["x-amz-security-token"])\n" *
              "/$bucket/$path?" *
              "response-content-disposition=attachment"

    key = aws[:creds].secret_key
    query["Signature"] = digest(MD_SHA1, to_sign, key) |> base64encode |> strip

    endpoint=aws_endpoint("s3", aws[:region], bucket)
    return "$endpoint/$path?$(format_query_str(query))"
end

s3_sign_url(a...;b...) = s3_sign_url(default_aws_config(), a...;b...)



end #module AWSS3

#==============================================================================#
# End of file.
#==============================================================================#
