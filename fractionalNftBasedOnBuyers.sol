// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "@openzeppelin/contracts/token/ERC721/ERC721.sol";
import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "@openzeppelin/contracts/security/Pausable.sol";
import "@openzeppelin/contracts/utils/math/SafeMath.sol";
import "@openzeppelin/contracts/security/ReentrancyGuard.sol";
import "@openzeppelin/contracts/access/Ownable.sol";
import "hardhat/console.sol";

contract FractionalNft is Pausable, ERC721, Ownable, ReentrancyGuard{
    using SafeMath for uint256;
    IERC20 private tokenAddress;

    event Deposit(address indexed sender, uint amount, uint balance);
    event SubmitTransaction(
        address indexed owner,
        uint indexed txIndex,
        address indexed to,
        uint256 _price,
        uint256 _tokenId
    );
    event ConfirmTransaction(address indexed owner, uint indexed txIndex);
    event RevokeConfirmation(address indexed owner, uint indexed txIndex);
    event ExecuteTransaction(address indexed owner, uint indexed txIndex);
    event TokenMint(address indexed to, uint256 indexed price, uint256 indexed tokenID);
    event TokenTransfered(
        address token,
        address from,
        address to,
        uint256 indexed value,
        uint256 indexed tokenId
    );

    Transaction[] private transactions;
    mapping(uint256 => mapping(address => bool)) private isOwner;
    mapping(uint => mapping(address => bool)) private isConfirmed;
    mapping(uint256 => uint256) private shareAmount;
    mapping(uint256 =>mapping(address => uint256)) public fractionalOwnersShares;
    //mapping the address of admin
    mapping(uint256 => NFT) private idToNFT;
    // NFT ID => owner
    mapping(uint256 => address payable) private idToOwner;
    // NFT ID => Price
    mapping(uint256 => uint256) private idToPrice;

   struct Transaction {
        address from;
        address to;
        uint8 sharesToSell;
        uint256 price;
        uint256 tokenId;
        bool executed;
        uint256 confirmationsRequired;
        uint currentConfirmations;
        uint256 startTime;
        uint256 endTime;
    }

    struct NFT {
        uint256 tokenID;
        address[] fractionalBuyer;
        uint256 price;
    }

    modifier onlyFractionalOwners(uint256 _tokenId) {
        require(isOwner[_tokenId][msg.sender], "No Nft owner");
        _;
    }

    modifier txExists(uint _txIndex) {
        require(_txIndex < transactions.length, "Tx does not exits");
        _;
    }

    modifier notExecuted(uint _txIndex) {
        require(!transactions[_txIndex].executed, "Tx already executed");
        _;
    }

    modifier notConfirmed(uint _txIndex) {
        require(!isConfirmed[_txIndex][msg.sender], "Tx already confirmed");
        _;
    }

    constructor(string memory name, string memory symbol) ERC721(name, symbol){
        _owner = msg.sender;
    }

    function _transferNFT(
        address _sender,
        address _receiver,
        uint256 _tokenId
    ) internal {
        _mint(_sender, _tokenId);
        transferFrom(_sender, _receiver, _tokenId);
    }

    function lockNFT(
        uint256 _tokenId,
        uint256 _sharesToSell,
        uint256 _pricePerShare,
        address _tokenAddress
    ) external whenNotPaused {
        _transferNFT(msg.sender, address(this), _tokenId);
        idToOwner[_tokenId] = payable(msg.sender);
        tokenAddress = IERC20(_tokenAddress);
        shareAmount[_tokenId] = _sharesToSell;
        tokenAddress.transferFrom(msg.sender, address(this), _sharesToSell);
        idToPrice[_tokenId] = _pricePerShare;
    }

    function buyFractionalSharesOfNft(uint256 _tokenId, uint256 _sharesToBuy)
        external
        payable whenNotPaused nonReentrant
    {
        require(
            msg.value == idToPrice[_tokenId].mul(_sharesToBuy),
            "Insufficient funds"
        );
        require(shareAmount[_tokenId] != 0, "No more shares");
        uint256 _amount = idToPrice[_tokenId].mul(_sharesToBuy);
        payable(idToOwner[_tokenId]).transfer(_amount);
        tokenAddress.transfer(msg.sender, _sharesToBuy);
        if(!isOwner[_tokenId][msg.sender]){
            idToNFT[_tokenId].fractionalBuyer.push(msg.sender);
            shareAmount[_tokenId] = shareAmount[_tokenId] - _sharesToBuy;
            isOwner[_tokenId][msg.sender] = true;
            fractionalOwnersShares[_tokenId][msg.sender] += _sharesToBuy;
        }else{
            fractionalOwnersShares[_tokenId][msg.sender] += _sharesToBuy;
            shareAmount[_tokenId] = shareAmount[_tokenId] - _sharesToBuy;
        }
    }

    function submitTransaction(
        uint256 _tokenId,
        uint256 _price,
        uint256 _numConfirmationsRequired,
        uint8 _sharesToSell,
        uint256 _startTime,
        uint256 _endTime,
        address _to
    ) external onlyFractionalOwners(_tokenId) whenNotPaused {
        require(
        _numConfirmationsRequired > 0 && _numConfirmationsRequired <= idToNFT[_tokenId].fractionalBuyer.length, "invalid required confirmation");
        require(_price > 0, "Price cannot be 0");
        require(_to != address(0), "Address cannot be 0");
        require(shareAmount[_tokenId] == 0, "SharesToSell should be 0");
        require(_startTime != 0 && _endTime != 0 && _endTime > _startTime, "Invalid parameters");
        require(block.timestamp >= _startTime, "Sale is not started yet");
        require(fractionalOwnersShares[_tokenId][msg.sender] >= _sharesToSell, "Not enough shares to sell");
        require(_startTime < _endTime, "Invalid timestamp");
        uint txIndex = transactions.length;
        transactions.push(
            Transaction({
                from: msg.sender,
                to: _to,
                tokenId: _tokenId,
                sharesToSell: _sharesToSell,
                price: _price,
                executed: false,
                confirmationsRequired: _numConfirmationsRequired,
                currentConfirmations: 0,
                startTime: block.timestamp + _startTime,
                endTime: block.timestamp + _endTime
            })
        );
        emit SubmitTransaction(msg.sender, txIndex, _to, _tokenId, _price);
    }

    function confirmTransaction(
        uint _txIndex,
        uint256 _tokenId
    ) external onlyFractionalOwners(_tokenId) txExists(_txIndex) notExecuted(_txIndex) notConfirmed(_txIndex) whenNotPaused {
        Transaction storage transaction = transactions[_txIndex];
        require(block.timestamp > transaction.startTime, "Sale is not started yet");
        require(transaction.from != msg.sender, "You cannot confirm the transaction");
        require(block.timestamp <= transaction.startTime + transaction.endTime, "Sale is over");
        transaction.currentConfirmations += 1;
        isConfirmed[_txIndex][msg.sender] = true;
        emit ConfirmTransaction(msg.sender, _txIndex);
    }

    function executeTransaction(
        uint _txIndex, uint256 _tokenId, address _to, uint256 _price
    ) external payable onlyFractionalOwners(_tokenId) txExists(_txIndex) notExecuted(_txIndex) whenNotPaused nonReentrant {
        Transaction storage transaction = transactions[_txIndex];
        require(block.timestamp > transaction.endTime, "Sale not over yet");
        require(transaction.to == _to && transaction.price == msg.value && transaction.tokenId == _tokenId, "Invalid input parameters");
        require(transaction.from == msg.sender, "Invalid fractional owner");
        require(
            transaction.currentConfirmations >= transaction.confirmationsRequired,
            "Required confirmation should be same"
        );
        require(_price != 0, "Price cannot be 0");
        uint256 priceForFractionalOwnersBasedOnBuyers = msg.value / idToNFT[_tokenId].fractionalBuyer.length;
        for (uint i = 0; i < idToNFT[_tokenId].fractionalBuyer.length; i++) {
            address payable fractionalBuyersofNft = payable(idToNFT[_tokenId].fractionalBuyer[i]);
            fractionalBuyersofNft.transfer(priceForFractionalOwnersBasedOnBuyers);
        }
        emit ExecuteTransaction(msg.sender, _txIndex);
        _transfer(address(this), _to, _tokenId);
    }

    function revokeConfirmation(
        uint _txIndex,
        uint256 _tokenId
    ) external onlyFractionalOwners(_tokenId) txExists(_txIndex) notExecuted(_txIndex) whenNotPaused {
        Transaction storage transaction = transactions[_txIndex];
        require(isConfirmed[_txIndex][msg.sender], "Tx not confirmed");
        transaction.currentConfirmations -= 1;
        isConfirmed[_txIndex][msg.sender] = false;
        emit RevokeConfirmation(msg.sender, _txIndex);
    }

    function changeNumConfirmationsRequired(uint _txIndex, uint256 _tokenId, uint256 _newNumConfirmationsRequired) external whenNotPaused onlyFractionalOwners(_tokenId) notExecuted(_txIndex) {
        Transaction storage transaction = transactions[_txIndex];
        require(transaction.from == msg.sender, "No owner for submited transaction");
        require(transaction.confirmationsRequired != _newNumConfirmationsRequired, "Already same");
        transaction.confirmationsRequired = _newNumConfirmationsRequired;
    }

    function pause() external {
        _pause();
    }

    function unpause() external {
        _unpause();
    }

    function getTransactions(
        uint _txIndex
    )
        external
        view
        returns (
            address from,
            address to,
            uint256 price,
            uint256 tokenId,
            bool executed,
            uint256 confirmationsRequired,
            uint256 currentConfirmations
        )
    {
        Transaction storage transaction = transactions[_txIndex];
        return (
            transaction.from,
            transaction.to,
            transaction.price,
            transaction.tokenId,
            transaction.executed,
            transaction.confirmationsRequired,
            transaction.currentConfirmations
        );
    }

    function getBuyers(uint256 _tokenId) external view returns(address[] memory){
        return idToNFT[_tokenId].fractionalBuyer;
    }

    function getTotalNftShares(uint256 _tokenId) external view returns(uint256){
        return shareAmount[_tokenId];
    }

    function getPerNftPrice(uint256 _tokenId) external view returns(uint256){
        return idToPrice[_tokenId];
    }

    function getNftOwner(uint256 _tokenId) external view returns(address){
        return idToOwner[_tokenId];
    }

    function getTransactionCount() external view returns (uint) {
        return transactions.length;
    }
}
