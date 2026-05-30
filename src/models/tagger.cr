require "json"

class Tagger
    include JSON::Serializable
    getter id : Int64
    getter pattern : String
    getter tag_id : Int64
    
    def initialize(@id, @pattern, @tag_id)
    end
    
    def self.create(path : String, tag_id : Int64)
        return Tagger.new(0, "%#{path}%", tag_id)
    end
    
    def self.from_row(row : DB::ResultSet)
        id = row.read(Int64)
        pattern = row.read(String)
        tag_id = row.read(Int64)
        
        return Tagger.new(id, pattern, tag_id)
    end
end