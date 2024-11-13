require "uri"

class QueryBuilder
    @db : DB::Database
    getter text : String
    property page : Int64
    @sql : String = ""
    getter unknown_tags = [] of String
    property sorting = "posts.id DESC"
    property path_filter : String?

    @@cache = [] of QueryBuilder

    MAX_QUERY_CACHE = 128
    DEFAULT_PAGE_SIZE = 40
    SORTING_TYPES = {
        "id" => "posts.id DESC",
        "id:desc" => "posts.id DESC",
        "id:asc" => "posts.id ASC",
        "kudos" => "posts.kudos DESC",
        "kudos:desc" => "posts.kudos DESC",
        "kudos:asc" => "posts.kudos ASC",
        "cum" => "posts.kudos DESC",
        "cum:desc" => "posts.kudos DESC",
        "cum:asc" => "posts.kudos ASC",
        "score" => "posts.kudos DESC",
        "score:desc" => "posts.kudos DESC",
        "score:asc" => "posts.kudos ASC",
        "random" => "RANDOM"
    }
    
    def initialize(@db, @text = "", @page = 0)
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

        valid_tag_names = [] of String

        working_text = @text

        # Extract path filter
        puts working_text
        raw_path_filter = (working_text.match(/path:"([^"]+)"/) || [] of String)[1]?
        if raw_path_filter
            puts raw_path_filter
            valid_tag_names << ((working_text.match(/path:"([^"]+)"/) || [] of String)[0]? || "")
            @path_filter = URI.encode_path(raw_path_filter)
            puts @path_filter
            working_text = working_text.sub(/path:"([^"]+)"/, "")
        end

        tag_names = working_text.strip.split(" ")
        tag_names.each do |name|
            next if name.empty?
            if name.starts_with?("sort:")
                begin
                    @sorting = SORTING_TYPES[name.lstrip("sort:")]
                    valid_tag_names << name
                rescue
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
                valid_tag_names << name
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

        if selects.empty?
            selects << "SELECT posts.* FROM posts JOIN post_tags ON posts.id = post_tags.post_id"
        end

        @text = valid_tag_names.join(" ")
        @sql = "#{ctes.empty? ? "" : "WITH RECURSIVE "}#{ctes.join(", ")} #{selects.join(" INTERSECT ")}#{@path_filter.nil? ? "" : " WHERE url LIKE ?"}#{negative_selects.empty? ? "" : " EXCEPT "}#{negative_selects.join(" EXCEPT ")}"
        @@cache << self
        return @sql + page_sql
    end
end