public class PlayerInfo
{
    public long Id { get; set; }
    public string Name { get; set; }
    public int Score { get; set; }

    public PlayerInfo(long id, string name, int score = 0)
    {
        Id = id;
        Name = name;
        Score = score;
    }

    // Native Godot Dictionaries are automatically serializable over RPC
    public Godot.Collections.Dictionary ToDictionary()
    {
        return new Godot.Collections.Dictionary
        {
            { "id", Id },
            { "name", Name },
            { "score", Score },
        };
    }

    public static PlayerInfo FromDictionary(Godot.Collections.Dictionary dict)
    {
        return new PlayerInfo(
            (long)dict["id"],
            (string)dict["name"],
            (int)dict["score"]
        );
    }
}