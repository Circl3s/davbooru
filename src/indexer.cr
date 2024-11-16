require "base64"
require "http/client"
require "http/headers"
require "mime"
require "uri"
require "uuid"
require "xml"

class Indexer
    @db : DB::Database
    property base_url : URI
    property username : String
    property password : String
    property total_media : Int64?
    property whitelist = [] of String
    property blacklist = [] of String
    @backup_number = 0

    def initialize(@db, url, @username, @password)
        @base_url = URI.parse(url)
        @whitelist = File.read_lines("./whitelist.davbooru")
        @blacklist = File.read_lines("./blacklist.davbooru")

        STDERR.puts "Warning: whitelist is empty. Please populate ./whitelist.davbooru with any folders to index." if @whitelist.empty?
    end

    def get_total(force_update : Bool = false) : Int64
        if @total_media == nil
            @total_media = (@db.scalar "SELECT COUNT(id) FROM posts").as(Int64) || -1_i64
        end

        return @total_media.not_nil!
    end

    def run
        File.copy("./davbooru.db", "./backup/davbooru.db.#{@backup_number}")
        File.copy("./davbooru.db-shm", "./backup/davbooru.db-shm.#{@backup_number}")
        File.copy("./davbooru.db-wal", "./backup/davbooru.db-wal.#{@backup_number}")
        puts "Starting indexing..."
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
                                    t.connection.exec "INSERT OR IGNORE INTO posts VALUES(NULL, ?, 0, NULL)", url.to_s
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
        puts "Indexing finished!"
        puts "#{get_total(true)} in database."
    end

    def generate_thumbnail(id, url)
        puts "Generating thumb for #{id}"
        name = "#{id}.webp"
        is_video = MIME.from_filename(url).includes?("video") || MIME.from_filename(url).includes?("gif")

        ffmpeg = Process.find_executable("ffmpeg")

        args = [] of String
        args << "-i"
        args << url.sub("https://", "https://#{@username}:#{password}@")
        args << "-t" if is_video
        args << "2" if is_video
        args << "-vf"
        args << "scale=-1:240"
        args << "-loop" if is_video
        args << "0" if is_video
        args << "./public/thumb/#{name}"

        status = Process.run(ffmpeg || "ffmpeg", args)
        if status.success?
            return "/thumb/#{name}"
        else
            raise "yeet"
        end
    end
end
