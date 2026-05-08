using Godot;
using System;

public partial class Player : CharacterBody2D
{
	public const float Speed = 300.0f;
	public const float JumpVelocity = -400.0f;

	[Export] public InputSynchronizer InputSync { get; set; }

	private int _lastHandledJumpInputSequence = 0;

    public override void _PhysicsProcess(double delta)
	{
		if (Multiplayer.IsServer())
		{
			ApplyMovement(delta);
		}
	}


	public void ApplyMovement(double delta)
	{
		Vector2 velocity = Velocity;

		// Add the gravity.
		if (!IsOnFloor())
		{
			velocity += GetGravity() * (float)delta;
		}

		// Handle Jump.
		if (InputSync.JumpInputSequence != _lastHandledJumpInputSequence)
		{
			_lastHandledJumpInputSequence = InputSync.JumpInputSequence;
			if (IsOnFloor())
			{
				velocity.Y = JumpVelocity;
			}
		}

		// Get the input direction and handle the movement/deceleration.
		// As good practice, you should replace UI actions with custom gameplay actions.
		Vector2 direction = InputSync.InputDirection;
		if (direction != Vector2.Zero)
		{
			velocity.X = direction.X * Speed;
		}
		else
		{
			velocity.X = Mathf.MoveToward(Velocity.X, 0, Speed);
		}

		Velocity = velocity;
		MoveAndSlide();
	}
}
