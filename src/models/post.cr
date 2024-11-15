require "mime"

class Post
    getter id : Int64
    getter url : String
    getter kudos : Int64
    setter thumbnail : String?
    @indexer : Indexer

    def initialize(@id, @url, @kudos, @thumbnail, @indexer)

    end

    def self.from_row(row : DB::ResultSet, indexer : Indexer)
        return self.new(row.read(Int64), row.read(String), row.read(Int64), row.read(String?), indexer)
    end

    def type
        return MIME.from_filename(@url)
    end

    def thumbnail
        if @thumbnail
            return @thumbnail if File.exists?("./public/thumb/#{@thumbnail}")
        end

        @thumbnail = @indexer.generate_thumbnail(self)
        return @thumbnail
    end
end