using Godot;
using System;

public partial class PlayerCard : PanelContainer
{
	[Export] private Label _nameLabel;
	[Export] private Label _idLabel;
	[Export] private Label _readylabel;
	public bool IsReady { get; private set; } = false;
	public string Id { get; private set; }
	public void Setup(String name, long id, bool ready)
	{
		_nameLabel.Text = name;
		_idLabel.Text = $"ID: {id}";
		IsReady = ready;
		UpdateReadyState(ready);
	}
	public void UpdateReadyState(bool isReady)
	{
		_readylabel.Text = isReady ? "Ready" : "Not Ready";
		IsReady = isReady;
	}
}
