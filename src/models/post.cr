require "mime"
require "uri"

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
        if File.exists?("./public/thumb/#{@id}.webp")
          return "/thumb/#{@id}.webp"
        else
          return "/post/#{@id}/thumbnail?url=#{URI.encode_path_segment(@url)}"
        end
    end
end
