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
    mapping(uint256 => mapping(address => bool)) public isOwner;
    mapping(uint => mapping(address => bool)) private isConfirmed;
    mapping(uint256 => uint256) private shareAmount;
    mapping(uint256 => mapping(address => uint256)) public fractionalOwnersShares;
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
        require(bytes(name).length > 0 && bytes(symbol).length > 0, "Invalid parameters");
        _owner = msg.sender;
    }

    function lockNFT(
        uint256 _tokenId,
        uint256 _sharesToSell,
        uint256 _pricePerShare,
        address _tokenAddress
    ) external whenNotPaused {
        require(_tokenAddress != address(0), "Address cannot be 0");
        require(_sharesToSell > 0 && _sharesToSell < 100, "Invalid SharesToSell");
        require(_pricePerShare > 0, "PricePerShare cannot be 0");
        idToOwner[_tokenId] = payable(msg.sender);
        tokenAddress = IERC20(_tokenAddress);
        shareAmount[_tokenId] = _sharesToSell;
        require(
            tokenAddress.allowance(msg.sender, address(this)) >= _sharesToSell,
            "Check the token allowance"
        );
        tokenAddress.transferFrom(msg.sender, address(this), _sharesToSell);
        require(!_exists(_tokenId), "Nft already exists");
        idToNFT[_tokenId].fractionalBuyer.push(msg.sender);
        isOwner[_tokenId][msg.sender] = true;
        fractionalOwnersShares[_tokenId][msg.sender] = 100 - _sharesToSell;
        _mint(msg.sender, _tokenId);
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
        require(_startTime != 0 && _endTime != 0 && _endTime > _startTime, "Invalid parameters");
        require(fractionalOwnersShares[_tokenId][msg.sender] >= _sharesToSell, "Not enough shares to sell");
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
                endTime: block.timestamp + _startTime + _endTime
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
        require(block.timestamp <= transaction.endTime, "Sale is over");
        transaction.currentConfirmations += 1;
        isConfirmed[_txIndex][msg.sender] = true;
        emit ConfirmTransaction(msg.sender, _txIndex);
    }

    function executeTransaction(
        uint _txIndex, uint256 _tokenId
    ) external payable  txExists(_txIndex) notExecuted(_txIndex) whenNotPaused nonReentrant {
        Transaction storage transaction = transactions[_txIndex];
        require(block.timestamp > transaction.endTime, "Sale not over yet");
        require(transaction.price == msg.value && transaction.tokenId == _tokenId, "Invalid input parameters");
        require(transaction.to == msg.sender, "Invalid fractional owner");
        require(transaction.currentConfirmations >= transaction.confirmationsRequired, "Required confirmation should be same");
        require(
            tokenAddress.allowance(transaction.from, address(this)) >= transaction.sharesToSell,
            "Check the token allowance"
        );
        uint256 totalShares = 0;
        for (uint i = 0; i < idToNFT[_tokenId].fractionalBuyer.length; i++) {
            totalShares += fractionalOwnersShares[_tokenId][idToNFT[_tokenId].fractionalBuyer[i]];
        }
        if (totalShares == 0) {
            revert("Cannot divide by zero");
        }
        uint256 smartContractFees = (msg.value * 2) / 100;
        uint256 priceForFractionalOwner = msg.value - smartContractFees;
        for (uint i = 0; i < idToNFT[_tokenId].fractionalBuyer.length; i++) {
            address payable fractionalBuyer = payable(idToNFT[_tokenId].fractionalBuyer[i]);
            uint256 priceForFractionalOwnersTotalShares = priceForFractionalOwner / totalShares;
            fractionalBuyer.transfer(priceForFractionalOwnersTotalShares);
        }
        fractionalOwnersShares[_tokenId][transaction.from] -= transaction.sharesToSell;
        fractionalOwnersShares[_tokenId][msg.sender] += transaction.sharesToSell;
        if(!isOwner[_tokenId][msg.sender]){
            idToNFT[_tokenId].fractionalBuyer.push(msg.sender);
            isOwner[_tokenId][msg.sender] = true;
        }
        tokenAddress.transferFrom(transaction.from, msg.sender, transaction.sharesToSell);
        // Delete staker's address from stakersList
        for (uint i = 0; i < idToNFT[_tokenId].fractionalBuyer.length; i++) {
            if (fractionalOwnersShares[_tokenId][idToNFT[_tokenId].fractionalBuyer[i]] == 0) {
                isOwner[_tokenId][idToNFT[_tokenId].fractionalBuyer[i]] = false;
                delete idToNFT[_tokenId].fractionalBuyer[i];
                if (i < idToNFT[_tokenId].fractionalBuyer.length - 1) {
                    // Shift the elements after the deleted element
                    for (uint j = i; j < idToNFT[_tokenId].fractionalBuyer.length - 1; j++) {
                        idToNFT[_tokenId].fractionalBuyer[j] = idToNFT[_tokenId].fractionalBuyer[j + 1];
                    }
                }
                // Remove the last element
                idToNFT[_tokenId].fractionalBuyer.pop();
                break;
            }
        }
        transaction.executed = true;
        emit ExecuteTransaction(msg.sender, _txIndex);
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

    function withdraw(address payable recipient) public onlyOwner nonReentrant {
        require(recipient != address(0), "Address cannot be zero");
        recipient.transfer(address(this).balance);
    }

    function withdrawTokenBalance(address _tokenAddress, address _recipient, uint256 _tokenId, uint256 _amount)
        external
        virtual
        nonReentrant
    {   
        require(_tokenAddress != address(0), "Address cannot be 0");
        require(_recipient != address(0), "Address cannot be zero");
        require(IERC20(_tokenAddress).balanceOf(address(this)) >= _amount, "Insufficient token balance");
        require(idToOwner[_tokenId] == payable(msg.sender), "Invalid nft owner");
        IERC20(_tokenAddress).transfer(msg.sender, _amount);
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
            uint256 startTime,
            uint256 endTime,
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
            transaction.startTime,
            transaction.endTime,
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
