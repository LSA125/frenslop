using Godot;
using System;
using System.Collections.Generic;
using System.Linq;

public partial class PlayersList : HBoxContainer
{
	// Called when the node enters the scene tree for the first time.
	[Export] private PackedScene _playerCardScene;
	[Export] private Button _readyButton;
	private Dictionary<long, PlayerCard> _playerCards = new Dictionary<long, PlayerCard>();
	private PlayerCard _localPlayerCard;
	private string TextToggle(string current)
	{
		return current == "Ready" ? "Not Ready" : "Ready";
	}
	public override void _Ready()
	{
		_readyButton.Pressed += _on_ready_button_pressed;
		MultiplayerManager.Instance.PlayerListChanged += OnPlayerListChanged;
		
		// Add existing players from the manager's dictionary
		foreach (var player in MultiplayerManager.Instance.Players.Values)
		{
			AddPlayerCard(player);
		}
	}

	private void AddPlayerCard(PlayerInfo player)
	{
		// Check if card already exists to avoid duplicates
		if (_playerCards.ContainsKey(player.Id))
		{
			//update
			_playerCards[player.Id].Setup(player.Name, player.Id, _playerCards[player.Id].IsReady);
			return;
		}

		PlayerCard card = _playerCardScene.Instantiate<PlayerCard>();
		card.Name = player.Id.ToString();
		card.SetMultiplayerAuthority((int)player.Id);
		this.AddChild(card);
		card.Setup(player.Name, player.Id, false);
		_playerCards[player.Id] = card;
		
		if (player.Id == MultiplayerManager.Instance.LocalPlayer.Id)
		{
			_localPlayerCard = card;
		}
	}

	private void RemovePlayerCard(long playerId)
	{
		if (_playerCards.TryGetValue(playerId, out PlayerCard card))
		{
			 _playerCards.Remove(playerId);
			card.QueueFree();
		}
	}

	private void _on_ready_button_pressed()
	{
		// Example: Toggle ready state for local player
		if (_localPlayerCard != null)
		{
			bool isReady = _localPlayerCard.IsReady;
			_localPlayerCard.UpdateReadyState(!isReady);
		}
		else
		{
			GD.PrintErr("Local player card not found!");
			return;
		}
	}

	private void OnPlayerListChanged()
	{
		// Get current player IDs from the manager
		var managerPlayerIds = MultiplayerManager.Instance.Players.Keys.ToHashSet();
		var currentCardIds = _playerCards.Keys.ToHashSet();

		// Remove cards for players that are no longer in the list
		foreach (var id in currentCardIds.Except(managerPlayerIds))
		{
			RemovePlayerCard(id);
		}

		// Add cards for new players
		foreach (var player in MultiplayerManager.Instance.Players.Values)
		{
			if (!currentCardIds.Contains(player.Id))
			{
				AddPlayerCard(player);
			}
		}
	}
	private bool AllReady()
	{
		return _playerCards.Values.All(card => card.IsReady);
	}
}
