public class PlayerInfo
{
    public long Id { get; set; }
    public string Name { get; set; }
    public string IpAddress { get; set; }

    public PlayerInfo(long id, string name, string IpAddress = "127")
    {
        Id = id;
        Name = name;
        this.IpAddress = IpAddress;
    }

    // Native Godot Dictionaries are automatically serializable over RPC
    public Godot.Collections.Dictionary ToDictionary()
    {
        return new Godot.Collections.Dictionary
        {
            { "id", Id },
            { "name", Name },
            { "ipAddress", IpAddress },
        };
    }

    public static PlayerInfo FromDictionary(Godot.Collections.Dictionary dict)
    {
        return new PlayerInfo(
            (long)dict["id"],
            (string)dict["name"],
            (string)dict["ipAddress"]
        );
    }
}