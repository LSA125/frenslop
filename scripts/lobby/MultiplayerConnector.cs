using Godot;
using System;

public partial class MultiplayerConnector : Node
{
	[Export] private LineEdit _nameInput;
	[Export] private Button _hostButton;
	[Export] private Button _joinButton;
	[Export] private Button _startButton;
	
	public override void _Ready()
	{
		_hostButton.Pressed += _on_host_button_pressed;
		_joinButton.Pressed += _on_join_button_pressed;
		_startButton.Pressed += _on_start_button_pressed;
		MultiplayerManager.Instance.GameStarted += OnGameStarted;
	}


	public void _on_host_button_pressed()
	{
		GD.Print("Hosting game...");
		MultiplayerManager.Instance.HostGame(_nameInput.Text);

	}
	public void _on_join_button_pressed()
	{
		GD.Print("Joining game...");
		MultiplayerManager.Instance.JoinGame("", _nameInput.Text);
		
	}
	public void _on_start_button_pressed()
	{
		GD.Print("Starting game...");
		MultiplayerManager.Instance.StartGame();
	}

	private void OnGameStarted()
	{
		GetTree().ChangeSceneToFile("res://scenes/MainScene.tscn");
		GD.Print("Successfully switched to main scene.");
	}
}
