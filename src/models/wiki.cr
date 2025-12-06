class Wiki
    property path : String
    property content : String

    def initialize(@path : String, @content : String)
    end

    def self.from_path(path : String)
        content = HTML.escape(File.read("./public/articles/#{path}")).gsub("`", "\\`")
        return Wiki.new(path, content)
    rescue
        return nil
    end

    def self.all_articles
        articles = [] of Wiki
        Dir.children("./public/articles").map do |file|
            wiki = Wiki.from_path(file)
            articles << wiki if wiki
        end
        return articles.sort_by { |a| a.path }
    end

    def title
        HTML.escape(content.lines.first.strip("# "))
    end

    def mentioned_tags(db : DB::Database)
        tags = [] of Tag
        links = content.scan(/\/tag\/(\d+)\/?/).flatten
        links.map do |link|
            id = link[1].to_i64
            tags << Tag.from_id(id, db)
        end
        return tags
    end
end