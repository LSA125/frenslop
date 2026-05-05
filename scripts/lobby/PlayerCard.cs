using Godot;
using System;

public partial class PlayerCard : PanelContainer
{
	[Export] private Label _nameLabel;
	[Export] private Label _idLabel;
	[Export] private Label _readylabel;
	[Signal] public delegate void ReadyStatusChangedEventHandler();
	private bool _isReady = false;
	[Export] public bool IsReady
	{ 
        get => _isReady;
        set 
        {
            _isReady = value;
            if (_readylabel != null) _readylabel.Text = value ? "Ready" : "Not Ready";
            EmitSignal(SignalName.ReadyStatusChanged);
        }
    }
    public override void _EnterTree()
    {
        base._EnterTree();
		SetMultiplayerAuthority(1);
    }

	public string Id { get; private set; }
	public void Setup(String name, long id, bool ready)
	{
		_nameLabel.Text = name;
		_idLabel.Text = $"ID: {id}";
		IsReady = ready;
	}
	public void UpdateReadyState(bool isReady)
	{
		IsReady = isReady;
	}
}
