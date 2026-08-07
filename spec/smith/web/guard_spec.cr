require "../../spec_helper"
require "../../../src/smith/web/guard"

private def check(url : String, allow_private : Bool = false)
  Smith::Web::Guard.check(URI.parse(url), allow_private: allow_private)
end

describe Smith::Web::Guard do
  it "allows a public address" do
    check("https://1.1.1.1/").should be_nil
  end

  it "blocks loopback" do
    check("https://127.0.0.1/").not_nil!.should contain("private")
    check("https://[::1]/").should_not be_nil
  end

  it "blocks the private ranges" do
    ["https://10.0.0.1/", "https://172.16.0.1/", "https://192.168.1.1/", "https://[fc00::1]/"].each do |url|
      check(url).should_not be_nil, url
    end
  end

  it "blocks link-local, which is where cloud metadata lives" do
    # 169.254.169.254 is the instance metadata endpoint on AWS, GCP and Azure.
    check("https://169.254.169.254/latest/meta-data/").should_not be_nil
    check("https://[fe80::1]/").should_not be_nil
  end

  it "does not mistake a neighbouring range for a private one" do
    # 172.32/12 is public; only 172.16/12 is not.
    check("https://172.32.0.1/").should be_nil
  end

  it "resolves a hostname before deciding" do
    # The check has to happen after DNS, or a name pointing at the metadata
    # endpoint walks straight past it.
    check("https://localhost/").should_not be_nil
  end

  it "lets private addresses through when explicitly allowed" do
    check("https://127.0.0.1/", allow_private: true).should be_nil
    check("https://169.254.169.254/", allow_private: true).should be_nil
  end

  it "rejects a scheme it will not speak" do
    check("file:///etc/passwd").not_nil!.should contain("scheme")
    check("ftp://example.com/").should_not be_nil
  end

  it "rejects a url with no host" do
    check("https:///nothing").should_not be_nil
  end

  it "reports a name that does not resolve, rather than raising" do
    check("https://this-host-does-not-exist.invalid/").not_nil!.should contain("resolve")
  end
end

describe "upgrading to https" do
  it "rewrites http to https" do
    Smith::Web::Guard.normalize(URI.parse("http://example.com/docs")).to_s
      .should eq("https://example.com/docs")
  end

  it "leaves https alone" do
    Smith::Web::Guard.normalize(URI.parse("https://example.com/")).to_s
      .should eq("https://example.com/")
  end

  it "leaves a bare host reachable" do
    Smith::Web::Guard.normalize(URI.parse("http://example.com")).scheme.should eq("https")
  end
end

describe "upgrading and local development" do
  it "leaves http alone when private targets are allowed" do
    # That setting is for local work, and a dev server on loopback rarely
    # speaks TLS — upgrading would defeat the option entirely.
    Smith::Web::Guard.normalize(URI.parse("http://127.0.0.1:3000/"), allow_private: true).scheme
      .should eq("http")
  end
end
