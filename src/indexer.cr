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
    property total_media : Int64?
    property tagged_media : Int64?
    property whitelist = [] of String
    property blacklist = [] of String
    @sqlite_cli : String?
    @backup_number = 0

    def initialize(@db, url, @username, @password)
        @base_url = URI.parse(url)
        @whitelist = File.read_lines("./whitelist.davbooru")
        @blacklist = File.read_lines("./blacklist.davbooru")

        STDERR.puts "Warning: Whitelist is empty. Please populate ./whitelist.davbooru with any folders to index." if @whitelist.empty?

        @sqlite_cli = Process.find_executable("sqlite3")
        STDERR.puts "Warning: Couldn't find sqlite3 command-line tool on your system. Automatic backups will not work." if @sqlite_cli.nil?
    end

    def update_lists
        @whitelist = File.read_lines("./whitelist.davbooru")
        @blacklist = File.read_lines("./blacklist.davbooru")
    end

    def get_total(force_update : Bool = false) : Int64
        if @total_media == nil || force_update
            @total_media = (@db.scalar "SELECT COUNT(id) FROM posts").as(Int64) || -1_i64
        end

        return @total_media.not_nil!
    end

    def get_tagged(force_update : Bool = false) : Int64
        if @tagged_media == nil || force_update
            @tagged_media = get_total - (@db.scalar "SELECT COUNT(DISTINCT(post_id)) FROM post_tags WHERE tag_id = 1").as(Int64) || -1_i64
        end

        return @tagged_media.not_nil!
    end

    def backup
        args = [] of String
        backup_name = "./backup/davbooru.db.#{@backup_number}"

        args << "./davbooru.db"
        args << ".backup '#{backup_name}'"

        begin
            raise "sqlite3 command-line tool not found" if @sqlite_cli.nil?
            status = Process.run(@sqlite_cli.not_nil!, args)
            if status.success?
                puts "Backup successfully created at #{backup_name}"
            else
                raise status.exit_reason.to_s
            end
        rescue e
            puts "Something went wrong while attempting backup: #{e}"
        end
        @backup_number = (@backup_number + 1) % 24
    end

    def run
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
                        current_href = ""
                        current_etag = ""
                        
                        while reader.read
                            if reader.node_type == XML::Reader::Type::ELEMENT
                                if reader.name == "D:href"
                                    reader.read
                                    current_href = reader.value
                                elsif reader.name == "D:getetag"
                                    reader.read
                                    current_etag = reader.value
                                end
                            elsif reader.node_type == XML::Reader::Type::END_ELEMENT
                                if reader.name == "D:response"
                                    # Process the response
                                    next if current_href.blank?
                                    
                                    url = @base_url.resolve(current_href)
                                    should_ignore = false
                                    @blacklist.each do |wrong|
                                        should_ignore = url.to_s.includes?(wrong.strip) && !wrong.blank?
                                        break if should_ignore
                                    end
                                    
                                    if !should_ignore
                                        type = "none"
                                        begin
                                            type = MIME.from_filename(url.to_s)
                                        rescue
                                        end
                                        
                                        if (type.includes?("image") || type.includes?("video"))
                                            # Check if URL already exists (Retroactive fill / No change)
                                            existing_id_by_url = nil
                                            t.connection.query "SELECT id FROM posts WHERE url = ?", url.to_s do |rs|
                                                rs.each do
                                                    existing_id_by_url = rs.read(Int64)
                                                end
                                            end

                                            if existing_id_by_url
                                                # Update etag if needed
                                                if !current_etag.blank?
                                                    t.connection.exec "UPDATE posts SET etag = ? WHERE id = ?", current_etag, existing_id_by_url
                                                end
                                            else
                                                # Check if Etag exists (Potential Move or Duplicate)
                                                move_candidate_id = nil
                                                
                                                if !current_etag.blank?
                                                    t.connection.query "SELECT id, url FROM posts WHERE etag = ?", current_etag do |rs|
                                                        rs.each do
                                                            candidate_id = rs.read(Int64)
                                                            candidate_url = rs.read(String)
                                                            
                                                            # Check if candidate URL still exists
                                                            candidate_exists = true
                                                            begin
                                                                check_uri = URI.parse(candidate_url)
                                                                check_client = HTTP::Client.new(check_uri)
                                                                check_client.connect_timeout = 5.seconds
                                                                check_client.read_timeout = 5.seconds
                                                                check_client.exec("HEAD", check_uri.request_target, headers) do |check_res|
                                                                    if check_res.status_code == 404
                                                                        candidate_exists = false
                                                                    end
                                                                end
                                                                check_client.close
                                                            rescue
                                                                # If check fails, assume it exists to be safe (treat as duplicate)
                                                            end

                                                            if !candidate_exists
                                                                move_candidate_id = candidate_id
                                                                break # Found a valid move source
                                                            end
                                                        end
                                                    end
                                                end

                                                if move_candidate_id
                                                    # Move detected (Old file is gone)
                                                    puts "Move detected: ID #{move_candidate_id} -> #{url}"
                                                    begin
                                                        t.connection.exec "UPDATE posts SET url = ? WHERE id = ?", url.to_s, move_candidate_id
                                                    rescue
                                                        # Collision (Shouldn't happen if we checked URL first, but just in case)
                                                        puts "Collision during move for #{url}. Deleting conflict."
                                                        t.connection.exec "DELETE FROM posts WHERE url = ?", url.to_s
                                                        t.connection.exec "UPDATE posts SET url = ? WHERE id = ?", url.to_s, move_candidate_id
                                                    end
                                                else
                                                    # Duplicate or New File
                                                    t.connection.exec "INSERT OR IGNORE INTO posts VALUES(NULL, ?, 0, ?)", url.to_s, current_etag
                                                end
                                            end
                                        end
                                    end
                                    
                                    # Reset for next response
                                    current_href = ""
                                    current_etag = ""
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
        puts "#{get_total(true)} in database, #{get_tagged(true)} of which are tagged."
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
