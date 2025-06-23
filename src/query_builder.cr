class QueryBuilder
    MAX_QUERY_CACHE = 128
    DEFAULT_PAGE_SIZE = 24
    SORTING_TYPES = {
        "id" => "id DESC",
        "id:desc" => "id DESC",
        "id:asc" => "id ASC",
        "kudos" => "kudos DESC",
        "kudos:desc" => "kudos DESC",
        "kudos:asc" => "kudos ASC",
        "cum" => "kudos DESC",
        "cum:desc" => "kudos DESC",
        "cum:asc" => "kudos ASC",
        "score" => "kudos DESC",
        "score:desc" => "kudos DESC",
        "score:asc" => "kudos ASC",
        "random" => "RANDOM()"
    }

    @db : DB::Database
    getter text : String
    property page : Int64
    @sql : String = ""
    getter unknown_tags = [] of String
    getter valid_tags = [] of String
    property sorting : String = SORTING_TYPES["id"]
    property path_filter : String?

    @@cache = [] of QueryBuilder

    
    
    def initialize(@db, @text = "", @page = 0)
        # Extract path filter
        raw_path_filter = (@text.match(/path:"([^"]+)"/) || [] of String)[1]?
        if raw_path_filter
            @valid_tags << ((@text.match(/path:"([^"]+)"/) || [] of String)[0]? || "")
            @path_filter = URI.encode_path(raw_path_filter)
        end
    end

    def text=(@text)
        @sql = ""
    end

    def cache
        @@cache
    end

    def page_sql
        # return " ORDER BY posts.id DESC LIMIT #{DEFAULT_PAGE_SIZE} OFFSET #{DEFAULT_PAGE_SIZE * @page}"
        return " ORDER BY #{@sorting}"
    end

    def sql
        if @sql != ""
            return @sql + page_sql
        end

        ctes = [] of String
        selects = [] of String
        negative_selects = [] of String

        working_text = @text.sub(/path:"([^"]+)"/, "")

        tag_names = working_text.strip.split(" ")
        tag_names.each do |name|
            next if name.blank?
            if name.starts_with?("sort:")
                begin
                    @sorting = SORTING_TYPES[name[5..]]
                    @valid_tags << name
                rescue e
                    puts e
                    @unknown_tags << name
                end
                next
            end
            negative = name.starts_with?("-")
            if negative
                name = name.lstrip("-")
            end
            tag = Tag.cache.values.find {|t| t.name == name}
            unless tag
                @db.query "SELECT tags.*, categories.name FROM tags JOIN categories ON tags.category_id = categories.id WHERE tags.name = ? LIMIT 1", name do |rs|
                    rs.each do
                        tag = Tag.from_row(rs)
                    end
                end
            end

            if tag.nil?
                @unknown_tags << name
                next
            else
                @valid_tags << name
                ctes << 
"hierarchy_#{tag.id} AS (
    SELECT *
    FROM tags
    WHERE id = #{tag.id}
    UNION ALL
    SELECT tags.*
    FROM tags JOIN hierarchy_#{tag.id} ON tags.parent_id = hierarchy_#{tag.id}.id
)"

                select_sql = 
"SELECT posts.*
FROM posts JOIN post_tags ON posts.id = post_tags.post_id JOIN hierarchy_#{tag.id} ON post_tags.tag_id = hierarchy_#{tag.id}.id
GROUP BY posts.id"

                if negative
                    negative_selects << select_sql
                else
                    selects << select_sql
                end
            end
        end

        if selects.empty? || @path_filter
            selects << "SELECT posts.* FROM posts JOIN post_tags ON posts.id = post_tags.post_id#{@path_filter.nil? ? "" : " WHERE url LIKE ?"} GROUP BY posts.id"
        end

        @sql = "#{ctes.empty? ? "" : "WITH RECURSIVE "}#{ctes.join(", ")} SELECT * FROM (#{selects.join(" INTERSECT ")}#{negative_selects.empty? ? "" : " EXCEPT "}#{negative_selects.join(" EXCEPT ")})"
        @@cache << self
        return @sql + page_sql
    end
end