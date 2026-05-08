using Godot;
using System;

public partial class InputSynchronizer : MultiplayerSynchronizer
{
	[Export] public Vector2 InputDirection { get; set; } = Vector2.Zero;
	[Export] public int JumpInputSequence { get; set; } = 0;

    public override void _EnterTree()
    {
		if (int.TryParse(GetParent().Name, out int peerId))
		{
			SetMultiplayerAuthority(peerId);
		}
    }

	public override void _Process(double delta)
	{
		if(IsMultiplayerAuthority())
		{
			InputDirection = Input.GetVector("MoveLeft", "MoveRight", "MoveUp", "MoveDown");
			if (Input.IsActionJustPressed("Jump"))
			{
				JumpInputSequence++;
			}
		}
	}
}
