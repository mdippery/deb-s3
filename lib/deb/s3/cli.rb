require "json"
require "net/http"

require "aws/s3"
require "thor"

require "deb/s3"
require "deb/s3/utils"
require "deb/s3/manifest"
require "deb/s3/package"
require "deb/s3/release"

class Deb::S3::CLI < Thor
  AMAZON_ACCESS_KEY_ID     = "AMAZON_ACCESS_KEY_ID"
  AMAZON_SECRET_ACCESS_KEY = "AMAZON_SECRET_ACCESS_KEY"

  constant :HOST, "169.254.169.254"
  constant :PATH, "/latest/meta-data/iam/security-credentials/"

  class_option :bucket,
  :type     => :string,
  :aliases  => "-b",
  :desc     => "The name of the S3 bucket to upload to."

  class_option :codename,
  :default  => "stable",
  :type     => :string,
  :aliases  => "-c",
  :desc     => "The codename of the APT repository."

  class_option :component,
  :default  => "main",
  :type     => :string,
  :aliases  => "-m",
  :desc     => "The component of the APT repository."

  class_option :section,
  :type     => :string,
  :aliases  => "-s",
  :hide     => true

  class_option :access_key,
  :type     => :string,
  :desc     => "The access key for connecting to S3."

  class_option :secret_key,
  :type     => :string,
  :desc     => "The secret key for connecting to S3."

  class_option :endpoint,
  :type     => :string,
  :desc     => "The region endpoint for connecting to S3."

  class_option :visibility,
  :default  => "public",
  :type     => :string,
  :aliases  => "-v",
  :desc     => "The access policy for the uploaded files. " +
    "Can be public, private, or authenticated."

  class_option :sign,
  :type     => :string,
  :desc     => "Sign the Release file when uploading a package," +
    "or when verifying it after removing a package." +
    "Use --sign with your key ID to use a specific key."

  class_option :gpg_options,
  :default => "",
  :type    => :string,
  :desc    => "Additional command line options to pass to GPG when signing"

  desc "upload FILES",
  "Uploads the given files to a S3 bucket as an APT repository."

  option :arch,
  :type     => :string,
  :aliases  => "-a",
  :desc     => "The architecture of the package in the APT repository."

  option :preserve_versions,
  :default  => false,
  :type     => :boolean,
  :aliases  => "-p",
  :desc     => "Whether to preserve other versions of a package " +
    "in the repository when uploading one."

  def upload(*files)
    component = options[:component]
    if options[:section]
      component = options[:section]
      warn("===> WARNING: The --section/-s argument is deprecated, please use --component/-m.")
    end

    if files.nil? || files.empty?
      error("You must specify at least one file to upload")
    end

    # make sure all the files exists
    if missing_file = files.detect { |f| !File.exists?(f) }
      error("File '#{missing_file}' doesn't exist")
    end

    # configure AWS::S3
    configure_s3_client

    # retrieve the existing manifests
    log("Retrieving existing manifests")
    release  = Deb::S3::Release.retrieve(options[:codename])
    manifests = {}

    # examine all the files
    files.collect { |f| Dir.glob(f) }.flatten.each do |file|
      log("Examining package file #{File.basename(file)}")
      pkg = Deb::S3::Package.parse_file(file)

      # copy over some options if they weren't given
      arch = options[:arch] || pkg.architecture

      # validate we have them
      error("No architcture given and unable to determine one for #{file}. " +
            "Please specify one with --arch [i386,amd64].") unless arch

      # retrieve the manifest for the arch if we don't have it already
      manifests[arch] ||= Deb::S3::Manifest.retrieve(options[:codename], component, arch)

      # add in the package
      manifests[arch].add(pkg, options[:preserve_versions])
    end

    # upload the manifest
    log("Uploading packages and new manifests to S3")
    manifests.each_value do |manifest|
      manifest.write_to_s3 { |f| sublog("Transferring #{f}") }
      release.update_manifest(manifest)
    end
    release.write_to_s3 { |f| sublog("Transferring #{f}") }

    log("Update complete.")
  end

  desc "verify", "Verifies that the files in the package manifests exist"

  option :fix_manifests,
  :default  => false,
  :type     => :boolean,
  :aliases  => "-f",
  :desc     => "Whether to fix problems in manifests when verifying."

  def verify
    component = options[:component]
    if options[:section]
      component = options[:section]
      warn("===> WARNING: The --section/-s argument is deprecated, please use --component/-m.")
    end

    configure_s3_client

    log("Retrieving existing manifests")
    release = Deb::S3::Release.retrieve(options[:codename])

    %w[i386 amd64 all].each do |arch|
      log("Checking for missing packages in: #{options[:codename]}/#{options[:component]} #{arch}")
      manifest = Deb::S3::Manifest.retrieve(options[:codename], component, arch)
      missing_packages = []

      manifest.packages.each do |p|
        unless Deb::S3::Utils.s3_exists? p.url_filename_encoded
          sublog("The following packages are missing:\n\n") if missing_packages.empty?
          puts(p.generate)
          puts("")

          missing_packages << p
        end
      end

      if options[:fix_manifests] && !missing_packages.empty?
        log("Removing #{missing_packages.length} package(s) from the manifest...")
        missing_packages.each { |p| manifest.packages.delete(p) }
        manifest.write_to_s3 { |f| sublog("Transferring #{f}") }
        release.update_manifest(manifest)
        release.write_to_s3 { |f| sublog("Transferring #{f}") }

        log("Update complete.")
      end
    end
  end

  private

  def log(message)
    puts ">> #{message}"
  end

  def sublog(message)
    puts "   -- #{message}"
  end

  def error(message)
    puts "!! #{message}"
    exit 1
  end

  def access_key
    if explicit?
      explicit_access_key
    else
      role_access_key
    end
  end

  def secret_key
    if explicit?
      explicit_secret_key
    else
      role_secret_key
    end
  end

  def security_token
    unless explicit?
      role_security_token
    end
  end

  def explicit_access_key
    options[:access_key] || ENV[AMAZON_ACCESS_KEY_ID]
  end

  def explicit_secret_key
    options[:secret_key] || ENV[AMAZON_SECRET_ACCESS_KEY]
  end

  def explicit?
    if explicit_access_key.nil? ^ explicit_secret_key.nil?
      error("The access and secret keys are both required for S3. Please specify them both.")
    end
    !explicit_access_key.nil? && !explicit_secret_key.nil?
  end

  def role
    unless @role
      @role = Net::HTTP.get(HOST, PATH)
    end
    @role
  end

  def role_credentials
    unless @creds
      creds = Net::HTTP.get(HOST, "#{PATH}#{role}/")
      @creds = JSON.parse(creds)
    end
    @creds
  end

  def role_access_key
    role_credentials["AccessKeyId"]
  end

  def role_secret_key
    role_credentials["SecretAccessKey"]
  end

  def role_security_token
    role_credentials["Token"]
  end

  def configure_s3_client
    error("No value provided for required options '--bucket'") unless options[:bucket]

    connection_options = {
      :access_key_id     => access_key,
      :secret_access_key => secret_key
    }
    connection_options[:security_token] = security_token if security_token
    AWS::S3::Base.establish_connection!(connection_options)

    AWS::S3::DEFAULT_HOST.replace options[:endpoint] if options[:endpoint]

    Deb::S3::Utils.bucket      = options[:bucket]
    Deb::S3::Utils.signing_key = options[:sign]
    Deb::S3::Utils.gpg_options = options[:gpg_options]

    # make sure we have a valid visibility setting
  Deb::S3::Utils.access_policy =
    case options[:visibility]
    when "public"
      :public_read
    when "private"
      :private
    when "authenticated"
      :authenticated_read
    else
      error("Invalid visibility setting given. Can be public, private, or authenticated.")
    end
  end
end
