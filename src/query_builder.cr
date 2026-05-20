class QueryBuilder
    MAX_QUERY_CACHE   = 128
    DEFAULT_PAGE_SIZE =  24
    SORTING_TYPES     = {
        "id"         => "id DESC",
        "id:desc"    => "id DESC",
        "id:asc"     => "id ASC",
        "newest"     => "id DESC",
        "oldest"     => "id ASC",

        "updated"    => "updated_at DESC",
        "updated:desc" => "updated_at DESC",
        "updated:asc"  => "updated_at ASC",
        "modified"    => "updated_at DESC",
        "modified:desc" => "updated_at DESC",
        "modified:asc"  => "updated_at ASC",

        "kudos"      => "kudos DESC",
        "kudos:desc" => "kudos DESC",
        "kudos:asc"  => "kudos ASC",
        "cum"        => "kudos DESC",
        "cum:desc"   => "kudos DESC",
        "cum:asc"    => "kudos ASC",
        "score"      => "kudos DESC",
        "score:desc" => "kudos DESC",
        "score:asc"  => "kudos ASC",

        "random"     => "RANDOM()",
    }

    @db : DB::Database
    getter text : String
    @blacklist : String
    @sql : String = ""
    getter unknown_tags = [] of String
    getter valid_tags = [] of String
    property sorting : String = SORTING_TYPES["id"]
    getter path_filters = [] of String

    @@cache = [] of QueryBuilder

    def initialize(@db, @text = "", @blacklist = "")
    end

    def text=(@text)
        @sql = ""
    end

    def cache
        @@cache
    end

    def page_sql
        return " ORDER BY #{@sorting}"
    end

    def sql
        if @sql != ""
            return @sql + page_sql
        end

        ctes = [] of String
        selects = [] of String
        negative_selects = [] of String

        working_text = @text

        if !@blacklist.blank?
            blacklisted_tags = @blacklist.strip.scan(/[^\s"]+(?:"[^"\\]*(?:\\.[^"\\]*)*"[^\s"]*)*|"[^"\\]*(?:\\.[^"\\]*)*"/)
            blacklisted_tags.each do |tag|
                working_text += " -#{tag}"
            end
        end

        tag_names = working_text.strip.scan(/[^\s"]+(?:"[^"\\]*(?:\\.[^"\\]*)*"[^\s"]*)*|"[^"\\]*(?:\\.[^"\\]*)*"/)
        tag_names.each do |match|
            name = match.to_s.strip.downcase
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

            if name.starts_with?("path:")
                path = name[5..].strip('"')
                select_sql = "SELECT posts.* FROM posts JOIN post_tags ON posts.id = post_tags.post_id WHERE url LIKE ? GROUP BY posts.id"
                @valid_tags << name
                @path_filters << "%#{URI.encode_path(path)}%"
            elsif name.starts_with?("album:") || name.starts_with?("pool:")
                begin
                    album_id = name.split(":")[1].to_i64
                    select_sql = "SELECT posts.* FROM posts JOIN album_posts ON posts.id = album_posts.post_id WHERE album_posts.album_id = #{album_id} GROUP BY posts.id"
                    @valid_tags << name
                rescue
                    @unknown_tags << name
                    next
                end
            elsif name.starts_with?("updated:") || name.starts_with?("modified:")
                begin
                    filter = name.sub("updated:", "").sub("modified:", "")
                    time_string = filter.sub("before:", "").sub("after:", "").sub("on:", "").strip("\"")
                    if time_string.downcase == "today"
                        time = Time.utc.at_beginning_of_day.to_unix
                    elsif time_string.downcase == "yesterday"
                        time = (Time.utc - 1.day).at_beginning_of_day.to_unix
                    else
                        time = Time::Format::ISO_8601_DATE.parse(time_string).to_unix
                    end
                    if filter.starts_with?("before:")
                        select_sql = "SELECT posts.* FROM posts JOIN post_tags ON posts.id = post_tags.post_id WHERE posts.updated_at < #{time} GROUP BY posts.id"
                    elsif filter.starts_with?("after:")
                        select_sql = "SELECT posts.* FROM posts JOIN post_tags ON posts.id = post_tags.post_id WHERE posts.updated_at > #{time + 86399} GROUP BY posts.id"
                    elsif filter.starts_with?("on:")
                        select_sql = "SELECT posts.* FROM posts JOIN post_tags ON posts.id = post_tags.post_id WHERE posts.updated_at BETWEEN #{time} AND #{time + 86400} GROUP BY posts.id"
                    else
                        @unknown_tags << name
                        next
                    end
                    @valid_tags << name
                rescue
                    @unknown_tags << name
                    next
                end
            elsif name.starts_with?("created:") || name.starts_with?("uploaded:")
                begin
                    filter = name.sub("created:", "").sub("uploaded:", "")
                    time_string = filter.sub("before:", "").sub("after:", "").sub("on:", "").strip("\"")
                    if time_string.downcase == "today"
                        time = Time.utc.at_beginning_of_day.to_unix
                    elsif time_string.downcase == "yesterday"
                        time = (Time.utc - 1.day).at_beginning_of_day.to_unix
                    else
                        time = Time::Format::ISO_8601_DATE.parse(time_string).to_unix
                    end
                    if filter.starts_with?("before:")
                        select_sql = "SELECT posts.* FROM posts JOIN post_tags ON posts.id = post_tags.post_id WHERE posts.created_at < #{time} GROUP BY posts.id"
                    elsif filter.starts_with?("after:")
                        select_sql = "SELECT posts.* FROM posts JOIN post_tags ON posts.id = post_tags.post_id WHERE posts.created_at > #{time + 86399} GROUP BY posts.id"
                    elsif filter.starts_with?("on:")
                        select_sql = "SELECT posts.* FROM posts JOIN post_tags ON posts.id = post_tags.post_id WHERE posts.created_at BETWEEN #{time} AND #{time + 86400} GROUP BY posts.id"
                    else
                        @unknown_tags << name
                        next
                    end
                    @valid_tags << name
                rescue
                    @unknown_tags << name
                    next
                end
            else
                tag = Tag.cache.values.find { |t| t.name == name }
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
)" if !ctes.join(", ").includes?("hierarchy_#{tag.id}")

                    select_sql =
"SELECT posts.*
FROM posts JOIN post_tags ON posts.id = post_tags.post_id JOIN hierarchy_#{tag.id} ON post_tags.tag_id = hierarchy_#{tag.id}.id
GROUP BY posts.id"
                end
            end

            if negative
                negative_selects << select_sql
            else
                selects << select_sql
            end
        end

        if selects.empty?
            selects << "SELECT posts.* FROM posts JOIN post_tags ON posts.id = post_tags.post_id GROUP BY posts.id"
        end

        @sql = "#{ctes.empty? ? "" : "WITH RECURSIVE "}#{ctes.join(", ")} SELECT * FROM (#{selects.join(" INTERSECT ")}#{negative_selects.empty? ? "" : " EXCEPT "}#{negative_selects.join(" EXCEPT ")})"
        @@cache << self
        return @sql + page_sql
    end
end