// SPDX-License-Identifier: MIT
pragma solidity 0.8.25;

import "https://raw.githubusercontent.com/OpenZeppelin/openzeppelin-contracts/v4.9.3/contracts/security/ReentrancyGuard.sol";
import "https://raw.githubusercontent.com/OpenZeppelin/openzeppelin-contracts/v4.9.3/contracts/access/Ownable.sol";

contract MilestoneEscrow is ReentrancyGuard, Ownable {
    enum MilestoneState { Created, Funded, Submitted, Approved, InDispute, Resolved, Released, Refunded }

    struct Milestone {
        uint256 id;
        address client;
        address freelancer;
        uint256 amount;
        uint256 deadline;
        string proof;
        MilestoneState state;
    }

    uint256 public milestoneCount;
    mapping(uint256 => Milestone) public milestones;
    mapping(address => uint256) public withdrawBalances;
    bool public paused;
    address public arbiter;

    event MilestoneCreated(uint256 indexed id, address indexed client, address indexed freelancer, uint256 amount, uint256 deadline);
    event MilestoneFunded(uint256 indexed id, address funder, uint256 amount);
    event DeliverySubmitted(uint256 indexed id, string proof, address submitter);
    event MilestoneApproved(uint256 indexed id, address approver);
    event DisputeRaised(uint256 indexed id, address raiser, string reason);
    event DisputeResolved(uint256 indexed id, address resolver, uint256 releaseToFreelancer, uint256 refundToClient);
    event Withdrawn(address indexed to, uint256 amount);
    event Paused(address indexed by);
    event Unpaused(address indexed by);
    event ArbiterChanged(address indexed oldArbiter, address indexed newArbiter);

    modifier notPaused() {
        require(!paused, "contract paused");
        _;
    }

    modifier onlyArbiter() {
        require(msg.sender == arbiter, "only arbiter");
        _;
    }

    constructor(address _arbiter) {
        require(_arbiter != address(0), "arbiter zero");
        arbiter = _arbiter;
        milestoneCount = 0;
        paused = false;
    }

    function createMilestone(address freelancer, uint256 amount, uint256 deadline) external notPaused returns (uint256) {
        require(freelancer != address(0), "freelancer zero");
        require(amount > 0, "amount zero");
        require(deadline > block.timestamp, "invalid deadline");
        milestoneCount += 1;
        milestones[milestoneCount] = Milestone({
            id: milestoneCount,
            client: msg.sender,
            freelancer: freelancer,
            amount: amount,
            deadline: deadline,
            proof: "",
            state: MilestoneState.Created
        });
        emit MilestoneCreated(milestoneCount, msg.sender, freelancer, amount, deadline);
        return milestoneCount;
    }

    function fundMilestone(uint256 id) external payable notPaused nonReentrant {
        Milestone storage m = milestones[id];
        require(m.id == id, "milestone not exist");
        require(m.state == MilestoneState.Created, "not fundable");
        require(msg.value == m.amount, "incorrect value");
        m.state = MilestoneState.Funded;
        emit MilestoneFunded(id, msg.sender, msg.value);
    }

    function submitDelivery(uint256 id, string calldata proof) external notPaused {
        Milestone storage m = milestones[id];
        require(m.id == id, "milestone not exist");
        require(msg.sender == m.freelancer, "only freelancer");
        require(m.state == MilestoneState.Funded, "not funded");
        require(block.timestamp <= m.deadline, "deadline passed");
        m.proof = proof;
        m.state = MilestoneState.Submitted;
        emit DeliverySubmitted(id, proof, msg.sender);
    }

    function approveMilestone(uint256 id) external notPaused nonReentrant {
        Milestone storage m = milestones[id];
        require(m.id == id, "milestone not exist");
        require(msg.sender == m.client, "only client");
        require(m.state == MilestoneState.Submitted, "not submitted");
        m.state = MilestoneState.Approved;
        withdrawBalances[m.freelancer] += m.amount;
        emit MilestoneApproved(id, msg.sender);
    }

    function raiseDispute(uint256 id, string calldata reason) external notPaused {
        Milestone storage m = milestones[id];
        require(m.id == id, "milestone not exist");
        require(msg.sender == m.client || msg.sender == m.freelancer, "not participant");
        require(m.state == MilestoneState.Submitted || m.state == MilestoneState.Funded, "cannot dispute now");
        m.state = MilestoneState.InDispute;
        emit DisputeRaised(id, msg.sender, reason);
    }

    function resolveDispute(uint256 id, uint256 releaseToFreelancer, uint256 refundToClient) external onlyArbiter notPaused nonReentrant {
        Milestone storage m = milestones[id];
        require(m.id == id, "milestone not exist");
        require(m.state == MilestoneState.InDispute || m.state == MilestoneState.Funded || m.state == MilestoneState.Submitted, "not disputable");
        require(releaseToFreelancer + refundToClient == m.amount, "sum mismatch");
        m.state = MilestoneState.Resolved;
        if (releaseToFreelancer > 0) withdrawBalances[m.freelancer] += releaseToFreelancer;
        if (refundToClient > 0) withdrawBalances[m.client] += refundToClient;
        emit DisputeResolved(id, msg.sender, releaseToFreelancer, refundToClient);
    }

    function refund(uint256 id) external notPaused nonReentrant {
        Milestone storage m = milestones[id];
        require(m.id == id, "milestone not exist");
        require(m.state == MilestoneState.Funded, "not refundable");
        require(block.timestamp > m.deadline + 7 days, "grace not passed");
        m.state = MilestoneState.Refunded;
        withdrawBalances[m.client] += m.amount;
    }

    function withdraw() external nonReentrant {
        uint256 bal = withdrawBalances[msg.sender];
        require(bal > 0, "no balance");
        withdrawBalances[msg.sender] = 0;
        (bool success, ) = msg.sender.call{value: bal}("");
        require(success, "transfer failed");
        emit Withdrawn(msg.sender, bal);
    }

    function pause() external onlyOwner {
        paused = true;
        emit Paused(msg.sender);
    }

    function unpause() external onlyOwner {
        paused = false;
        emit Unpaused(msg.sender);
    }

    function setArbiter(address newArbiter) external onlyOwner {
        require(newArbiter != address(0), "arbiter zero");
        address old = arbiter;
        arbiter = newArbiter;
        emit ArbiterChanged(old, newArbiter);
    }
}
