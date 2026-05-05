using Godot;
using System;
using System.Collections.Generic;
using System.Linq;

public partial class PlayersList : HBoxContainer
{
	// Called when the node enters the scene tree for the first time.
	[Export] private PackedScene _playerCardScene;
	[Export] private Button _readyButton;
	[Export] private Button _startButton;
	public override void _Ready()
	{
		_readyButton.Pressed += OnReadyButtonPressed;
		ChildExitingTree += OnChildExitedTree;
	}
	private void AddPlayerCard(PlayerInfo player)
	{
		//check if card already exists
		foreach(PlayerCard child in GetChildren())
		{
			if(child.Name == player.Id.ToString())
			{
				child.Setup(player.Name, player.Id, false);
				return;
			}
		}
		PlayerCard card = _playerCardScene.Instantiate<PlayerCard>();
		card.Name = player.Id.ToString();
		card.Setup(player.Name, player.Id, false);
		AddChild(card);
		card.ReadyStatusChanged += OnReadyChanged;
	}
	private void OnReadyButtonPressed()
	{
		// Example: Toggle ready state for local player
		if(Multiplayer.IsServer())
		{
			var card = GetNode<PlayerCard>(MultiplayerManager.Instance.LocalPlayer.Id.ToString());
			card.UpdateReadyState(!card.IsReady);
			OnReadyChanged();
		}
		else
		{
			RpcId(1, MethodName.ServerToggleReady, MultiplayerManager.Instance.LocalPlayer.Id);
		}
	}
	[Rpc(MultiplayerApi.RpcMode.AnyPeer, TransferMode = MultiplayerPeer.TransferModeEnum.Reliable)]
	private void ServerToggleReady(long playerId)
	{
		if (!Multiplayer.IsServer()) return;
		
		var card = GetNode<PlayerCard>(playerId.ToString());
		card.UpdateReadyState(!card.IsReady);
	}
	public void OnPlayerListChanged()
	{
		// Sync player cards with the current player list
		var currentIds = GetChildren().OfType<PlayerCard>().Select(c => c.Name).ToHashSet();
		var managerIds = MultiplayerManager.Instance.Players.Keys.Select(id => id.ToString()).ToHashSet();
		// Add new players
		foreach (var player in MultiplayerManager.Instance.Players.Values)
		{
			if (!currentIds.Contains(player.Id.ToString()))
			{
				AddPlayerCard(player);
			}
		}
		// Remove disconnected players
		foreach (var card in GetChildren().OfType<PlayerCard>())
		{
			if (!managerIds.Contains(card.Name))
			{
				card.QueueFree();
			}
		}
	}
	private void OnReadyChanged()
	{
		if(Multiplayer.MultiplayerPeer != null && Multiplayer.IsServer()) {_startButton.Disabled = !AllReady();}
	}
	private bool AllReady()
	{
		return GetChildren().OfType<PlayerCard>().All(card => card.IsReady);
	}

	#region Destructors and Signal disconnectors
	private void OnChildExitedTree(Node node)
	{
		if (node is PlayerCard card)
		{
			card.ReadyStatusChanged -= OnReadyChanged;
			OnReadyChanged(); 
		}
	}
    public override void _ExitTree()
    {
		MultiplayerManager.Instance.PlayerListChanged -= OnPlayerListChanged;
        base._ExitTree();
    }
	#endregion
}