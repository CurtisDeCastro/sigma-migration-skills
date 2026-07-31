#!/usr/bin/env ruby
# Fetch warehouse column metadata for one or more table inodeIds in parallel.
# Encapsulates the "response key is `entries`, not `columns`" gotcha and the
# Sigma auth refresh.
#
# Usage:
#   ruby discover-warehouse-columns.rb <out-dir> <inodeId> [<inodeId> ...]

require 'net/http'
require 'uri'
require 'json'
require 'fileutils'

OUT_DIR = ARGV.shift || abort('usage: discover-warehouse-columns.rb <out-dir> <inodeId>+')
INODES  = ARGV
abort 'no inodeIds given' if INODES.empty?

BASE = ENV.fetch('SIGMA_BASE_URL')
$LOAD_PATH.unshift File.expand_path('lib', __dir__)
require 'sigma_rest'
FileUtils.mkdir_p(OUT_DIR)

# Fans out to N inodes in parallel; Sigma.request handles 401-refresh
# (single-flight mutex so threads don't all refresh at once).
#
# PAGINATED. Sigma.list_entries sends limit=1000 and follows nextPage to
# exhaustion, and returns the concatenated entries already parsed — it requests
# accept: application/json, so there is no raw body to JSON.parse and no
# `entries` key to remember. A bare first-page GET truncated wide tables at the
# server default of 50.
#
# Deliberately NO `http:` injection: one thread per inode, so each must open its
# own connection (the library default). A shared Net::HTTP would be raced.
threads = INODES.map do |inode|
  Thread.new do
    cols = Sigma.list_entries("/v2/connections/tables/#{inode}/columns")
    File.write("#{OUT_DIR}/#{inode}.json", JSON.pretty_generate(cols))
    [inode, cols.size]
  end
end

threads.each(&:join).map(&:value).each do |inode, n|
  puts "  #{inode}: #{n} columns"
end
