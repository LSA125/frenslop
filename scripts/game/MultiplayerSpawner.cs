using Godot;
using System;

public partial class MultiplayerSpawner : Godot.MultiplayerSpawner
{
	[Export] private PackedScene _playerScene;
	// Called when the node enters the scene tree for the first time.
	public override void _Ready()
	{
		if(Multiplayer.IsServer())
		{
			int counter = 0;
			foreach(int playerId in MultiplayerManager.Instance.Players.Keys)
			{
				GD.Print($"Spawning player for ID {playerId}");
				Player playerInstance = (_playerScene.Instantiate() as Player)
					?? throw new InvalidOperationException("Failed to instantiate player scene.");
				playerInstance.Name = playerId.ToString();
				playerInstance.Position = new Vector2(100*counter, 100);
				GetNode<Node2D>(SpawnPath).AddChild(playerInstance, true);
				counter++;
				GD.Print($"Spawned player {playerId} at position {playerInstance.Position}");
			}
		}
	}
}
