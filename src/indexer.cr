require "base64"
require "http/client"
require "http/headers"
require "mime"
require "uri"
require "xml"

class Indexer
    @db : DB::Database
    property base_url : URI
    property username : String
    property password : String
    property whitelist = [] of String
    property blacklist = [] of String

    def initialize(@db, url, @username, @password)
        @base_url = URI.parse(url)
        @whitelist = File.read_lines("./whitelist.davbooru")
        @blacklist = File.read_lines("./blacklist.davbooru")

        STDERR.puts "Warning: whitelist is empty. Please populate ./whitelist.davbooru with any folders to index." if @whitelist.empty?
    end

    def run
        headers = HTTP::Headers.new.add("Authorization", "Basic #{Base64.urlsafe_encode(@username + ":" + @password)}")
        @whitelist.each do |path|
            begin
                client = HTTP::Client.new(@base_url.resolve("/"))
                client.connect_timeout = 5.minutes
                client.read_timeout = 5.minutes
                client.exec("PROPFIND", path, headers) do |res|
                    reader = XML::Reader.new(res.body_io)
                    @db.transaction do |t|
                        while reader.read == true
                            if reader.name == "D:href"
                                reader.read
                                url = @base_url.resolve(reader.value)
                                should_ignore = false
                                @blacklist.each do |wrong|
                                    should_ignore = url.to_s.includes?(wrong.strip)
                                end
                                next if should_ignore
                                type = "none"
                                begin
                                    type = MIME.from_filename(url.to_s)
                                rescue
                                end
                                if (type.includes?("image") || type.includes?("video"))
                                    t.connection.exec "INSERT OR IGNORE INTO posts VALUES(NULL, \"#{url.to_s}\", 0)"
                                end
                            end
                        end
                        t.commit
                    end
                end
                client.close
                puts "#{path} done!"
            rescue e
                puts "Warning: failed indexing #{path}: #{e}"
            end
        end
    end
end