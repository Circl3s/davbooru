require "mime"

class Post
    getter id : Int64
    getter url : String
    getter kudos : Int64

    def initialize(@id, @url, @kudos)

    end

    def self.from_row(row : DB::ResultSet)
        return self.new(row.read(Int64), row.read(String), row.read(Int64))
    end

    def type
        return MIME.from_filename(@url)
    end
end