#
# Cookbook Name:: scala-jenkins-infra
# Recipe:: _worker-config-debian
#
# Copyright 2014, Typesafe, Inc.
#
# All rights reserved - Do Not Redistribute
#

# This can only be run *after* bootstrap due to vault dependency
# thus, factored out of worker-linux.
# Also, it needs to run on every reboot of the worker instance(s),
# since jenkins's home dir is mounted on ephemeral storage (see chef/userdata/ubuntu-publish-c3.xlarge)

require 'chef-vault'
require 'base64'

node["jenkinsHomes"].each do |jenkinsHome, workerConfig|
  user workerConfig["jenkinsUser"] do
    home jenkinsHome
  end

  directory jenkinsHome do
    owner workerConfig["jenkinsUser"]
    group workerConfig["jenkinsUser"]
    mode 00755
    action :create
  end

  directory "#{jenkinsHome}/.ssh" do
    owner workerConfig["jenkinsUser"]
  end

  file "#{jenkinsHome}/.ssh/authorized_keys" do
    owner workerConfig["jenkinsUser"]
    mode  '644'
    content ChefVault::Item.load("master", "scala-jenkins-keypair")['public_key'] # TODO: distinct keypair for each jenkins user
  end

  git_user workerConfig["jenkinsUser"] do
    full_name   'Scala Jenkins'
    email       'adriaan@typesafe.com'
  end

  if workerConfig["publish"]
    jenkinsUser=workerConfig["jenkinsUser"]

    # TODO: recursive doesn't set owner correctly (???), so list out all dirs explicitly
    ["#{jenkinsHome}/.ssh", "#{jenkinsHome}/.ivy2", "#{jenkinsHome}/.m2", "#{jenkinsHome}/.sbt", "#{jenkinsHome}/.sbt/0.13", "#{jenkinsHome}/.sbt/0.13/plugins/"].each do |dir|
      directory dir do
        user jenkinsUser
      end
    end

    file "#{jenkinsHome}/.ssh/for_chara" do
      owner jenkinsUser
      mode '600'
      sensitive true
      content ChefVault::Item.load("worker-publish", "chara-keypair")['private_key']
    end

    execute 'accept chara host key' do
      command "ssh -oStrictHostKeyChecking=no scalatest@chara.epfl.ch -i \"#{jenkinsHome}/.ssh/for_chara\" true"
      user jenkinsUser
      #
      # not_if "grep -qs \"#{ChefVault::Item.load("worker-publish", "chara-keypair")['public_key']}\" #{jenkinsHome}/.ssh/known_hosts"
    end

    directory "#{jenkinsHome}/.gnupg" do
      owner workerConfig["jenkinsUser"]
    end

    ["sec", "pub"].each do |kind|
      file "#{jenkinsHome}/.gnupg/#{kind}ring.gpg" do
        owner jenkinsUser
        mode '600'
        sensitive true
        content Base64.decode64(ChefVault::Item.load("worker-publish", "gnupg")["#{kind}ring-base64"])
      end
    end

    { "#{jenkinsHome}/.credentials-private-repo" => "credentials-private-repo.erb",
      "#{jenkinsHome}/.credentials-sonatype"     => "credentials-sonatype.erb",
      "#{jenkinsHome}/.credentials"              => "credentials-sonatype.erb", # TODO: remove after replacing references to it in scripts by `.credentials-sonatype`
      "#{jenkinsHome}/.sonatype-curl"            => "sonatype-curl.erb",
      "#{jenkinsHome}/.s3credentials"            => "s3credentials.erb",
      "#{jenkinsHome}/.m2/settings.xml"          => "m2-settings.xml.erb"
    }.each do |target, templ|
      template target do
        source templ
        user jenkinsUser
        sensitive true

        variables({
          :sonatypePass    => ChefVault::Item.load("worker-publish", "sonatype")['pass'],
          :sonatypeUser    => ChefVault::Item.load("worker-publish", "sonatype")['user'],
          :privateRepoPass => ChefVault::Item.load("worker-publish", "private-repo")['pass'],
          :privateRepoUser => ChefVault::Item.load("worker-publish", "private-repo")['user'],
          :s3DownloadsPass => ChefVault::Item.load("worker-publish", "s3-downloads")['pass'],
          :s3DownloadsUser => ChefVault::Item.load("worker-publish", "s3-downloads")['user']
        })
      end
    end

    template "#{jenkinsHome}/.sbt/0.13/plugins/gpg.sbt" do
      source "sbt-0.13-plugins-gpg.sbt.erb"
      user jenkinsUser
    end

    %w{zip xz-utils rpm dpkg lintian fakeroot}.each do |pkg|
      package pkg
    end
  end
end