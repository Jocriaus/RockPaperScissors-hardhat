// SPDX-License-Identifier: MIT
pragma solidity ^0.8.17;

// import "hardhat/console.sol"; // Import for debugging purposes

contract RockPaperScissors {
    // 1. Core Game Logic

    // Enums for moves and game state are more gas efficient
    enum Move {
        Invalid, // 0
        Rock,    // 1
        Paper,   // 2
        Scissors // 3
    }

    enum GameState {
        WaitingForPlayer1, // 0
        WaitingForPlayer2, // 1
        AwaitingReveal,    // 2
        GameOver         // 3
    }

    struct Game {
        address player1;
        address player2;
        bytes32 commitment1; // Hashed move of player 1
        bytes32 commitment2; // Hashed move of player 2
        uint256 betAmount1;  // Bet amount of player 1
        uint256 betAmount2;  // Bet amount of player 2
        Move move1;         // Revealed move of player 1
        Move move2;         // Revealed move of player 2
        GameState state;
        uint256 timeout; // Timestamp for reveal timeout
    }

    mapping(uint256 => Game) public games; // gameId => Game
    uint256 public nextGameId;
    uint256 public revealTimeout = 1 days; // 1 day reveal timeout

    event GameStarted(uint256 gameId, address player1, address player2);
    event MoveCommitted(uint256 gameId, address player, bytes32 commitment);
    event BetSent(uint256 gameId, address player, uint256 amount);
    event MoveRevealed(uint256 gameId, address player, Move move);
    event WinnerDetermined(uint256 gameId, address winner, Move move1, Move move2);
    event GameAborted(uint256 gameId);
    event FundsDistributed(uint256 gameId, address winner, uint256 amount);
    event FundsReturned(uint256 gameId, address player1, uint256 amount1, address player2, uint256 amount2);


    /**
     * @notice Starts a new game, player1 is the caller, player2 is the opponent
     * @param player2 The address of the second player.
     * @param commitment1 The hashed move of player 1.
     */
    function startGame(address player2, bytes32 commitment1) external {
        require(player2 != address(0), "Player 2 cannot be address(0)");
        require(player2 != msg.sender, "Players cannot be the same");
        require(commitment1 != bytes32(0), "Commitment cannot be empty");

        uint256 gameId = nextGameId++;
        games[gameId] = Game({
            player1: msg.sender,
            player2: player2,
            commitment1: commitment1,
            commitment2: bytes32(0), // Initialize as empty
            betAmount1: 0,
            betAmount2: 0,
            move1: Move.Invalid,
            move2: Move.Invalid,
            state: GameState.WaitingForPlayer2,
            timeout: 0
        });

        emit GameStarted(gameId, msg.sender, player2);
        emit MoveCommitted(gameId, msg.sender, commitment1);
        // console.log("Game started with ID:", gameId); // Debug log
    }

    /**
     * @notice Joins an existing game.
     * @param gameId The ID of the game to join.
     * @param commitment2 The hashed move of player 2.
     */
    function joinGame(uint256 gameId, bytes32 commitment2) external {
        Game storage game = games[gameId];
        require(game.state == GameState.WaitingForPlayer2, "Game is not waiting for player 2");
        require(msg.sender == game.player2, "Only player 2 can join");
        require(commitment2 != bytes32(0), "Commitment cannot be empty");

        game.commitment2 = commitment2;
        game.state = GameState.AwaitingReveal;
        game.timeout = block.timestamp + revealTimeout; // Set the timeout
        emit MoveCommitted(gameId, msg.sender, commitment2);
        emit MoveCommitted(gameId, msg.sender, commitment2); // Emit again for player 2
        // console.log("Player 2 joined game:", gameId);
    }

    /**
     * @notice Player sends their bet for the game.
     * @param gameId The ID of the game.
     */
    function sendBet(uint256 gameId) external payable {
        Game storage game = games[gameId];
        require(game.state == GameState.AwaitingReveal, "Bets can only be sent during AwaitingReveal state");

        if (msg.sender == game.player1) {
            require(game.betAmount1 == 0, "Bet amount already set");
            game.betAmount1 = msg.value;
        } else if (msg.sender == game.player2) {
            require(game.betAmount2 == 0, "Bet amount already set");
            game.betAmount2 = msg.value;
        } else {
            revert("You are not a player in this game");
        }
        emit BetSent(gameId, msg.sender, msg.value);
        // console.log("Bet of", msg.value, "sent by", msg.sender, "for game:", gameId);
    }

    /**
     * @notice Reveals a player's move.
     * @param gameId The ID of the game.
     * @param move The player's move (1=Rock, 2=Paper, 3=Scissors).
     * @param salt The salt used to hash the move.
     */
    function revealMove(uint256 gameId, Move move, bytes32 salt) external {
        Game storage game = games[gameId];
        require(game.state == GameState.AwaitingReveal, "Moves can only be revealed in AwaitingReveal state");
        require(move != Move.Invalid, "Move cannot be invalid");
        require(block.timestamp <= game.timeout, "Reveal timeout expired");

        bytes32 expectedCommitment = keccak256(abi.encodePacked(move, salt));

        if (msg.sender == game.player1) {
            require(game.move1 == Move.Invalid, "Move already revealed"); // prevent double reveal
            require(game.commitment1 == expectedCommitment, "Invalid commitment for Player 1");
            game.move1 = move;
            emit MoveRevealed(gameId, msg.sender, move);
            // console.log("Player 1 revealed move:", uint256(move), "for game:", gameId);

        } else if (msg.sender == game.player2) {
             require(game.move2 == Move.Invalid, "Move already revealed");
            require(game.commitment2 == expectedCommitment, "Invalid commitment for Player 2");
            game.move2 = move;
            emit MoveRevealed(gameId, msg.sender, move);
            // console.log("Player 2 revealed move:", uint256(move), "for game:", gameId);
        } else {
            revert("You are not a player in this game");
        }

        // Check if both moves are revealed
        if (game.move1 != Move.Invalid && game.move2 != Move.Invalid) {
            determineWinner(gameId);
        }
    }

    /**
     * @notice Determines the winner and distributes funds.
     * @param gameId The ID of the game.
     */
    function determineWinner(uint256 gameId) private {
        Game storage game = games[gameId];
        require(game.state == GameState.AwaitingReveal, "Winner can only be determined in AwaitingReveal state");
        require(game.move1 != Move.Invalid && game.move2 != Move.Invalid, "Both moves must be revealed");

        uint256 totalBetAmount = game.betAmount1 + game.betAmount2;
        address winner = address(0); // 0x0 means nobody wins

        if (game.move1 == game.move2) {
            // Tie
            emit WinnerDetermined(gameId, address(0), game.move1, game.move2); // Emit winner as 0x0
            emit FundsReturned(gameId, game.player1, game.betAmount1, game.player2, game.betAmount2);
            (bool success1, ) = game.player1.call{value: game.betAmount1}("");
            (bool success2, ) = game.player2.call{value: game.betAmount2}("");
            require(success1 && success2, "Failed to return funds");
            // console.log("Game", gameId, "is a tie. Funds returned.");

        } else if (
            (game.move1 == Move.Rock && game.move2 == Move.Scissors) ||
            (game.move1 == Move.Paper && game.move2 == Move.Rock) ||
            (game.move1 == Move.Scissors && game.move2 == Move.Paper)
        ) {
            winner = game.player1;
            emit WinnerDetermined(gameId, winner, game.move1, game.move2);
            (bool success, ) = winner.call{value: totalBetAmount}("");
            require(success, "Failed to send funds to winner");
            emit FundsDistributed(gameId, winner, totalBetAmount);
            // console.log("Player 1 wins game:", gameId);

        } else {
            winner = game.player2;
            emit WinnerDetermined(gameId, winner, game.move1, game.move2);
            (bool success, ) = winner.call{value: totalBetAmount}("");
            require(success, "Failed to send funds to winner");
            emit FundsDistributed(gameId, winner, totalBetAmount);
            // console.log("Player 2 wins game:", gameId);
        }

        game.state = GameState.GameOver;
    }

    /**
     * @notice Aborts the game and refunds bets if a player doesn't reveal in time.
     * @param gameId The ID of the game to abort.
     */
    function abortGame(uint256 gameId) external {
        Game storage game = games[gameId];
        require(game.state == GameState.AwaitingReveal, "Game must be in AwaitingReveal state to abort");
        require(block.timestamp > game.timeout, "Game timeout has not expired");

        emit GameAborted(gameId);
        emit FundsReturned(gameId, game.player1, game.betAmount1, game.player2, game.betAmount2); // Use FundsReturned

        (bool success1, ) = game.player1.call{value: game.betAmount1}("");
        (bool success2, ) = game.player2.call{value: game.betAmount2}("");

        require(success1 && success2, "Failed to refund bets");

        game.state = GameState.GameOver; // Set game state to GameOver to prevent further interaction.
        // console.log("Game", gameId, "aborted due to timeout");
    }

    // Function to get the game state
    function getGameState(uint256 gameId) external view returns (GameState) {
        return games[gameId].state;
    }

      // Function to get the bet amounts
    function getBetAmounts(uint256 gameId) external view returns (uint256, uint256) {
        return (games[gameId].betAmount1, games[gameId].betAmount2);
    }
}
