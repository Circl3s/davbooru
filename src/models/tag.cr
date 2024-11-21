require "json"

class Tag
    include JSON::Serializable
    property id         : Int64
    property name       : String
    property category_id : Int64
    property parent_id  : Int64?
    property description : String
    property category_name : String
    property color : String = "gray"

    COLORS = ["gray", "orange", "red", "green", "violet", "skyblue"]

    @@cache = {} of Int64 => Tag

    def self.cache
        return @@cache
    end

    def initialize(@id, @name, @category_id, @parent_id, @description, @category_name)
        @@cache[@id] = self
        @color = COLORS[@category_id - 1]
    end

    def self.from_row(row : DB::ResultSet)
        return Tag.new(row.read(Int64), row.read(String), row.read(Int64), row.read(Int64?), row.read(String), row.read(String))
    end

    def self.from_id(id : Int64, db : DB::Database)
        tag = @@cache[id]
        if tag.nil?
            db.query "SELECT * FROM tags WHERE id=#{id}" do |rs|
                rs.each do
                    tag = Tag.from_row(rs)
                end
            end
        end
        raise "Couldn't create tag #{id}" if tag.nil?
        return tag.not_nil!
    end

    def parent(db : DB::Database)
        if @parent_id.nil?
            return nil
        else
            begin
                cached_tag = Tag.cache[@parent_id.not_nil!]
            rescue
                cached_tag = nil
            end
            return cached_tag if cached_tag

            db.query "SELECT * FROM tags WHERE id = #{@parent_id} LIMIT 1" do |rs|
                rs.each do
                    tag = Tag.from_row(rs)
                    Tag.cache[@parent_id.not_nil!] = tag
                    return tag
                end
            end
        end
    end
end