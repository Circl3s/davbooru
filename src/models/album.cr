class Album
  property id : Int64
  property name : String
  property description : String

  def initialize(@id, @name, @description)
  end

  def self.from_row(row : DB::ResultSet)
    id = row.read(Int64)
    name = row.read(String)
    description = row.read(String)

    return Album.new(id, name, description)
  end

  def posts(db : DB::Database, indexer : Indexer)
    posts = [] of Post
    db.query "SELECT posts.* FROM posts JOIN album_posts ON posts.id = album_posts.post_id WHERE album_posts.album_id = ? ORDER BY album_posts.\"order\" ASC", @id do |rs|
      rs.each do
        posts << Post.from_row(rs, indexer)
      end
    end
    return posts
  end

  def thumbnail(db : DB::Database, indexer : Indexer)
    posts = posts(db, indexer)
    if posts.empty?
      return nil
    end
    return posts.first.thumbnail
  end
end
