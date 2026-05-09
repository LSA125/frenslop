using Godot;
using System;

public partial class MovingPlatform : AnimatableBody2D
{
	[Export] int speed = 100;
	[Export] int distance_y = 200;
	[Export] int distance_x = 200;
	[Export] float lerp_factor = 0.9f;
	Vector2 start_position;
	Vector2 end_position;
	bool moving_to_end = true;
	[Export] Vector2 server_position;

	public override void _Ready()
	{
		start_position = GlobalPosition;
		end_position = new Vector2(start_position.X + distance_x, start_position.Y + distance_y);
		server_position = start_position;
	}

	public override void _PhysicsProcess(double delta)
	{
		if(Multiplayer.IsServer())
		{
			MovePlatform(delta);
			server_position = GlobalPosition;
		}
		else
		{
			GlobalPosition = GlobalPosition.Lerp(server_position, lerp_factor);
		}
	}

	private void MovePlatform(double delta)
	{
		Vector2 target_position = moving_to_end ? end_position : start_position;
		GlobalPosition = GlobalPosition.MoveToward(target_position, speed * (float)delta);

		if (GlobalPosition.DistanceTo(target_position) < 5)
		{
			moving_to_end = !moving_to_end;
		}
	}
}
