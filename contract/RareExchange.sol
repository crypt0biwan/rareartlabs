pragma solidity ^0.4.11;

import "zeppelin-solidity/contracts/math/SafeMath.sol";
import "./Libraries/RedBlackTree.sol";
import "zeppelin-solidity/contracts/token/ERC20/ERC20.sol";
import "./RareExchangeInterface.sol";
import "./Owned.sol";

contract RareExchange is RareExchangeInterface, Owned {
    using SafeMath for uint;
    using RedBlackTree for RedBlackTree.Tree;
    struct Balance {
        uint reserved;
        uint available;
    }
    struct ListItem {
        uint64 prev;
        uint64 next;
    }
    struct Order {
        address owner;
        address token;
        uint amount;
        uint price;
        bool sell;
        uint64 timestamp;
    }
    struct Pair {
        mapping (uint64 => ListItem) orderbook;
        RedBlackTree.Tree pricesTree;
        uint64 firstOrder;
        uint64 bestBid;
        uint64 bestAsk;
        uint64 lastOrder;
    }
    address constant public ETH = 0x0;
    bool private stopped = false;
    mapping (address => mapping (address => Balance)) private balances;
    mapping (address => uint) private accounted;
    uint64 lastOrderId;
    mapping(uint64 => Order) orders;
    mapping(address => Pair) pairs;
    event Deposit(address indexed token, address indexed owner, uint amount);
    event Withdraw(address indexed token, address indexed owner, uint amount);
    event NewOrder(address indexed token, address indexed owner, uint64 id, bool sell, uint price, uint amount, uint64 timestamp);
    event NewAsk(address indexed token, uint price);
    event NewBid(address indexed token, uint price);
    event NewTrade(address indexed token, uint64 indexed bidId, uint64 indexed askId, bool side, uint amount, uint price, uint timestamp);
    event OrderCancelled(address indexed token,address indexed owner,uint64 id);
    modifier isToken(address token) {
            require(token != 0);
        _;
    }
    modifier stopInEmergency {
          require(!stopped);
      _;
    }
    modifier onlyInEmergency {
          require(stopped);
       _;
    }
    function constructor() public {

    }
    function deposit(address token,uint amount) external payable stopInEmergency {
            require(token == ETH || msg.value == 0);
        uint value = amount;
        if (token == ETH) {
              value = msg.value;
        } else {
              require(ERC20(token).transferFrom(msg.sender,address(this),value));
        }
        depositFor(msg.sender,token,value);
    }
    function depositFor(address user, address token, uint amount) private {
            balances[token][user].available = balances[token][user].available.add(amount);
        emit Deposit(token,user,amount);
    }
    function withdraw(address token, uint amount) external {
            require(balanceAvailable(token,msg.sender) >= amount);
        balances[token][msg.sender].available = balances[token][msg.sender].available.sub(amount);
        withdrawTo(msg.sender,token,amount);
        emit Withdraw(token, msg.sender, amount);
    }
    function withdrawTo(address user, address token, uint amount) private {
          if (token == ETH) {
            user.transfer(amount);
        return;
      }
      require(ERC20(token).transfer(user, amount));
    }
    function askCreate(address token, uint amount, uint price) public stopInEmergency returns (uint64) {
            balances[token][msg.sender].available = balances[token][msg.sender].available.sub(amount);
        balances[token][msg.sender].reserved = balances[token][msg.sender].reserved.add(amount);
        Order memory order;
        order.token = token;
        order.sell = true;
        order.owner = msg.sender;
        order.price = price;
        order.amount = amount;
        order.timestamp = uint64(now);
        uint64 id = ++lastOrderId;
        emit NewOrder(token, msg.sender, id, true, price, amount, order.timestamp);
        Pair storage pair = pairs[token];
        matchSell(token, pair, order, id);
        if (order.amount != 0) {
                uint64 currentOrderId;
            uint64 n = pair.pricesTree.find(price);
            if (n != 0 && price >= orders[n].price) {
                    currentOrderId = pair.orderbook[n].next;
            } else {
                    currentOrderId = n;
            }
            ListItem memory orderItem;
            orderItem.next = currentOrderId;
            uint64 prevOrderId;
            if (currentOrderId != 0) {
                    prevOrderId = pair.orderbook[currentOrderId].prev;
                pair.orderbook[currentOrderId].prev = id;
            } else {
                    prevOrderId = pair.lastOrder;
                pair.lastOrder = id;
            }
            orderItem.prev = prevOrderId;
            if (prevOrderId != 0) {
                    pair.orderbook[prevOrderId].next = id;
            } else {
                    pair.firstOrder = id;
            }
            if (currentOrderId == pair.bestAsk) {
                    pair.bestAsk = id;
                emit NewAsk(token, order.price);
            }
            orders[id] = order;
            pair.orderbook[id] = orderItem;
            pair.pricesTree.placeAfter(n, id, price);
        }
        return id;
    }
    function matchSell(address token, Pair storage pair, Order order, uint64 id) private {
            uint64 currentOrderId = pair.bestBid;
        while (currentOrderId != 0 && order.amount != 0 && order.price <= orders[currentOrderId].price) {
                Order memory matchingOrder = orders[currentOrderId];
            uint tradeAmount;
            if (matchingOrder.amount >= order.amount) {
                    tradeAmount = order.amount;
                matchingOrder.amount -= order.amount;
                order.amount = 0;
            } else {
                    tradeAmount = matchingOrder.amount;
                order.amount -= matchingOrder.amount;
                matchingOrder.amount = 0;
            }
            balances[token][msg.sender].reserved = balances[token][msg.sender].reserved.sub(tradeAmount);
            balances[token][matchingOrder.owner].available = balances[token][matchingOrder.owner].available.add(tradeAmount);
            balances[0][matchingOrder.owner].reserved = balances[0][matchingOrder.owner].reserved.sub(tradeAmount.mul(matchingOrder.price));
            balances[0][msg.sender].available = balances[0][msg.sender].available.add(tradeAmount.mul(matchingOrder.price));
            emit NewTrade(token, currentOrderId, id, false, tradeAmount, matchingOrder.price, uint64(now));
            if (matchingOrder.amount != 0) {
                    orders[currentOrderId] = matchingOrder;
                break;
            }
            ListItem memory item = excludeItem(pair, currentOrderId);
            currentOrderId = item.prev;
        }
        if (pair.bestBid != currentOrderId) {
                pair.bestBid = currentOrderId;
            emit NewBid(token, orders[currentOrderId].price);
        }
    }
    function bidCreate(address token, uint amount, uint price) public stopInEmergency returns (uint64) {
            balances[0][msg.sender].available = balances[0][msg.sender].available.sub(amount.mul(price));
        balances[0][msg.sender].reserved = balances[0][msg.sender].reserved.add(amount.mul(price));
        Order memory order;
        order.token = token;
        order.sell = false;
        order.owner = msg.sender;
        order.price = price;
        order.amount = amount;
        order.timestamp = uint64(now);
        uint64 id = ++lastOrderId;
        emit NewOrder(token, msg.sender, id, false, price, amount, order.timestamp);
        Pair storage pair = pairs[token];
        matchBuy(token, pair, order, id);
        if (order.amount != 0) {
                uint64 currentOrderId;
            uint64 n = pair.pricesTree.find(price);
            if (n != 0 && price <= orders[n].price) {
                    currentOrderId = pair.orderbook[n].prev;
            } else {
                    currentOrderId = n;
            }
            ListItem memory orderItem;
            orderItem.prev = currentOrderId;
            uint64 prevOrderId;
            if (currentOrderId != 0) {
                    prevOrderId = pair.orderbook[currentOrderId].next;
                pair.orderbook[currentOrderId].next = id;
            } else {
                    prevOrderId = pair.firstOrder;
                pair.firstOrder = id;
            }
            orderItem.next = prevOrderId;
            if (prevOrderId != 0) {
                    pair.orderbook[prevOrderId].prev = id;
            } else {
                    pair.lastOrder = id;
            }
            if (currentOrderId == pair.bestBid) {
                    pair.bestBid = id;
                emit NewBid(token, order.price);
            }
            orders[id] = order;
            pair.orderbook[id] = orderItem;
            pair.pricesTree.placeAfter(n, id, order.price);
        }
        return id;
    }
    function matchBuy(address token, Pair storage pair, Order order, uint64 id) private {
            uint64 currentOrderId = pair.bestAsk;
        while (currentOrderId != 0 && order.amount > 0 && order.price >= orders[currentOrderId].price) {
                Order memory matchingOrder = orders[currentOrderId];
            uint tradeAmount;
            if (matchingOrder.amount >= order.amount) {
                    tradeAmount = order.amount;
                matchingOrder.amount -= order.amount;
                order.amount = 0;
            } else {
                    tradeAmount = matchingOrder.amount;
                order.amount -= matchingOrder.amount;
                matchingOrder.amount = 0;
            }
            balances[0][order.owner].reserved = balances[0][order.owner].reserved.sub(tradeAmount.mul(order.price));
            balances[0][order.owner].available = balances[0][order.owner].available.add(tradeAmount.mul(order.price - matchingOrder.price));
            balances[token][matchingOrder.owner].reserved = balances[token][matchingOrder.owner].reserved.sub(tradeAmount);
            balances[0][matchingOrder.owner].available = balances[0][matchingOrder.owner].available.add(tradeAmount.mul(matchingOrder.price));
            balances[token][order.owner].available = balances[token][order.owner].available.add(tradeAmount);
            emit NewTrade(token, id, currentOrderId, true, tradeAmount, matchingOrder.price, uint64(now));
            if (matchingOrder.amount != 0) {
                    orders[currentOrderId] = matchingOrder;
                break;
            }
            ListItem memory item = excludeItem(pair, currentOrderId);
            currentOrderId = item.next;
                    }
                    if (pair.bestAsk != currentOrderId) {
                            pair.bestAsk = currentOrderId;
                        emit NewAsk(token, orders[currentOrderId].price);
                    }
                }
                function cancelOrder(address token, uint64 id) isToken(token) public stopInEmergency {
                        Order memory order = orders[id];
                    require(order.owner == msg.sender);
                    require(order.token == token);
                    if (order.sell) {
                            balances[token][msg.sender].reserved = balances[token][msg.sender].reserved.sub(order.amount);
                        balances[token][msg.sender].available = balances[token][msg.sender].available.add(order.amount);
                    } else {
                            balances[0][msg.sender].reserved = balances[0][msg.sender].reserved.sub(order.amount.mul(order.price));
                        balances[0][msg.sender].available = balances[0][msg.sender].available.add(order.amount.mul(order.price));
                    }
                    Pair storage pair = pairs[token];
                    ListItem memory orderItem = excludeItem(pair, id);
                    if (pair.bestBid == id) {
                            pair.bestBid = orderItem.prev;
                        emit NewBid(token, orders[pair.bestBid].price);
                    } else if (pair.bestAsk == id) {
                            pair.bestAsk = orderItem.next;
                        emit NewAsk(token, orders[pair.bestAsk].price);
                    }
                    emit OrderCancelled(token,msg.sender,id);
                }
                function excludeItem(Pair storage pair, uint64 id) private returns (ListItem) {
                        ListItem memory matchingOrderItem = pair.orderbook[id];
                    if (matchingOrderItem.next != 0) {
                            pair.orderbook[matchingOrderItem.next].prev = matchingOrderItem.prev;
                    }
                    if (matchingOrderItem.prev != 0) {
                            pair.orderbook[matchingOrderItem.prev].next = matchingOrderItem.next;
                    }
                    if (pair.lastOrder == id) {
                            pair.lastOrder = matchingOrderItem.prev;
                    }
                    if (pair.firstOrder == id) {
                            pair.firstOrder = matchingOrderItem.next;
                    }
                    pair.pricesTree.remove(id);
                    delete pair.orderbook[id];
                    delete orders[id];
                    return matchingOrderItem;
                }
                function getBalance(address token, address trader) public constant returns (uint available, uint reserved) {
                        available = balances[token][trader].available;
                    reserved = balances[token][trader].reserved;
                }
                function balanceAvailable(address token, address user) private returns (uint) {
                        return balances[token][user].available;
                }
                function getOrderBookInfo(address token) public constant returns (uint64 firstOrder, uint64 bestBid, uint64 bestAsk, uint64 lastOrder) {
                        Pair memory pair = pairs[token];
                    firstOrder = pair.firstOrder;
                    bestBid = pair.bestBid;
                    bestAsk = pair.bestAsk;
                    lastOrder = pair.lastOrder;
                }
                function getOrder(address token, uint64 id) public constant returns (uint price, bool sell, uint amount, uint64 next, uint64 prev) {
                        Order memory order = orders[id];
                    price = order.price;
                    sell = order.sell;
                    amount = order.amount;
                    next = pairs[token].orderbook[id].next;
                    prev = pairs[token].orderbook[id].prev;
                }
                function stopContract() public onlyOwner {
                      stopped = true;
                }
                function recoverToken(address token) external onlyInEmergency {
                      uint amount = balances[token][msg.sender].available + balances[token][msg.sender].reserved;
                  withdrawTo(msg.sender,token,amount);
                }
            }
            