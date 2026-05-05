using Godot;
using System.Collections.Generic;
using System.Linq;

public partial class MultiplayerManager : Node
{
    [Signal] public delegate void PlayerListChangedEventHandler();
    [Signal] public delegate void ConnectionFailedEventHandler();
    [Signal] public delegate void GameStartedEventHandler();

    [Export] private int _port = 8910;
    [Export] private string _defaultAddress = "127.0.0.1";

    public static MultiplayerManager Instance { get; private set; }

    // Using a Dictionary for faster lookups by PeerID
    public Dictionary<long, PlayerInfo> Players { get; private set; } = new();
    
    public PlayerInfo LocalPlayer { get; private set; } = null;
    private ENetMultiplayerPeer _peer;

    public override void _Ready()
    {
        // Singleton pattern for Godot Autoloads
        if (Instance != null)
        {
            QueueFree();
            return;
        }
        Instance = this;

        // Connections
        Multiplayer.ConnectedToServer += OnConnectedToServer;
        Multiplayer.ConnectionFailed += OnConnectionFailed;
        Multiplayer.ServerDisconnected += OnServerDisconnected;
        Multiplayer.PeerConnected += OnPeerConnected;
        Multiplayer.PeerDisconnected += OnPeerDisconnected;
    }

    #region Public API

    public void HostGame(string playerName)
    {
        if (string.IsNullOrEmpty(playerName)) playerName = $"Host_{GD.Randi() % 1000}";
        _peer = new ENetMultiplayerPeer();
        var error = _peer.CreateServer(_port);
        
        if (error != Error.Ok)
        {
            GD.PushError($"Failed to host: {error}");
            return;
        }
        _peer.Host.Compress(ENetConnection.CompressionMode.RangeCoder);
        Multiplayer.MultiplayerPeer = _peer;
        
        LocalPlayer = new PlayerInfo(1, playerName);
        Players[1] = LocalPlayer;
        
        EmitSignal(SignalName.PlayerListChanged);
        GD.Print("Server started.");
    }

    public void JoinGame(string address, string playerName)
    {
        if (string.IsNullOrEmpty(address)) address = _defaultAddress;
        if (string.IsNullOrEmpty(playerName)) playerName = $"Player_{GD.Randi() % 1000}";
        _peer = new ENetMultiplayerPeer();
        var error = _peer.CreateClient(address, _port);
        _peer.Host.Compress(ENetConnection.CompressionMode.RangeCoder);
        if (error != Error.Ok)
        {
            GD.PushError($"Failed to start client: {error}");
            return;
        }

        LocalPlayer = new PlayerInfo(0, playerName); // ID set on connection
        Multiplayer.MultiplayerPeer = _peer;
        GD.Print("Client started, connecting...");
    }

    public void StartGame()
    {
        if (Multiplayer.IsServer())
        {
            Rpc(MethodName.RpcStartGame);
        }
    }

    #endregion

    #region Signal Handlers

    private void OnConnectedToServer()
    {
        LocalPlayer.Id = Multiplayer.GetUniqueId();
        RpcId(1, MethodName.ServerRegisterPlayer, LocalPlayer.Name);
        GD.Print($"Connected to server with ID {LocalPlayer.Id}");
    }

    private void OnConnectionFailed()
    {
        EmitSignal(SignalName.ConnectionFailed);
        Multiplayer.MultiplayerPeer = null;
    }

    private void OnServerDisconnected()
    {
        Multiplayer.MultiplayerPeer = null;
        Players.Clear();
        GetTree().ChangeSceneToFile("res://scenes/MainMenu.tscn");
        
    }

    private void OnPeerConnected(long id) => GD.Print($"Peer {id} connecting...");

    private void OnPeerDisconnected(long id)
    {
        if (Players.ContainsKey(id))
        {
            Players.Remove(id);
            EmitSignal(SignalName.PlayerListChanged);
        }
    }

    #endregion

    #region RPC Methods

    // Clients call this on the Server (ID 1)
    [Rpc(MultiplayerApi.RpcMode.AnyPeer, TransferMode = MultiplayerPeer.TransferModeEnum.Reliable)]
    private void ServerRegisterPlayer(string name)
    {
        if (!Multiplayer.IsServer()) return;

        long id = Multiplayer.GetRemoteSenderId();
        Players[id] = new PlayerInfo(id, name);

        // Sync the full state to all clients
        SyncPlayerList();
    }

    // Server calls this to force all clients to match its dictionary
    [Rpc(MultiplayerApi.RpcMode.Authority, TransferMode = MultiplayerPeer.TransferModeEnum.Reliable, CallLocal = true)]
    private void UpdatePlayerList(Godot.Collections.Array<Godot.Collections.Dictionary> data)
    {
        Players.Clear();
        foreach (var dict in data)
        {
            var p = PlayerInfo.FromDictionary(dict);
            Players[p.Id] = p;
        }
        EmitSignal(SignalName.PlayerListChanged);
    }


    [Rpc(MultiplayerApi.RpcMode.Authority, CallLocal = true)]
    private void RpcStartGame()
    {
        EmitSignal(SignalName.GameStarted);
    }

    #endregion

    private void SyncPlayerList()
    {
        // Convert Dictionary to a Godot-compatible Array of Dictionaries for RPC
        var data = new Godot.Collections.Array<Godot.Collections.Dictionary>();
        foreach (var player in Players.Values)
        {
            data.Add(player.ToDictionary());
        }
        Rpc(MethodName.UpdatePlayerList, data);
    }
}