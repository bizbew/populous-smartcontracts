/**
This is the core module of the system. Currently it holds the code of
the Bank and crowdsale modules to avoid external calls and higher gas costs.
It might be a good idea in the future to split the code, separate Bank
and crowdsale modules into external files and have the core interact with them
with addresses and interfaces. 
*/
pragma solidity ^0.4.17;

import "./CurrencyToken.sol";
import "./iCrowdsale.sol";
import "./iCrowdsaleManager.sol";
import "./iDepositContractsManager.sol";


/// @title Populous contract
contract Populous is withAccessManager {

    // EVENTS

    // Bank events
    event EventNewCurrency(bytes32 tokenName, uint8 decimalUnits, bytes32 tokenSymbol, address addr);
    event EventMintTokens(bytes32 currency, uint amount);
    event EventDestroyTokens(bytes32 currency, uint amount);
    event EventInternalTransfer(bytes32 currency, bytes32 fromId, bytes32 toId, uint amount);
    event EventWithdrawal(address to, bytes32 clientId, bytes32 currency, uint amount, uint fee);
    event EventDeposit(address from, bytes32 clientId, bytes32 currency, uint amount);
    event EventImportedPokens(address from, bytes32 clientId, bytes32 currency, uint amount);

    // crowdsale events
    //event EventNewCrowdsale(address crowdsale, bytes32 _currencySymbol, bytes32 _borrowerId, bytes32 _invoiceId, string _invoiceNumber, uint _invoiceAmount, uint _fundingGoal, uint deadline);
    event EventBeneficiaryFunded(address crowdsaleAddr, bytes32 borrowerId, bytes32 currency, uint amount);
    event EventLosingGroupBidderRefunded(address crowdsaleAddr, uint groupIndex, bytes32 bidderId, bytes32 currency, uint amount);
    event EventPaymentReceived(address crowdsaleAddr, bytes32 currency, uint amount, uint feeAmount);
    event EventWinnerGroupBidderFunded(address crowdsaleAddr, uint groupIndex, bytes32 bidderId, bytes32 currency, uint bidAmount, uint benefitsAmount);

    event EventExchange(bytes32 clientId, bytes32 from_currency, bytes32 to_currency, uint amount, string conversion_rate, uint from_amount, uint fee_amount);


    // FIELDS

    // Constant fields

    bytes32 constant LEDGER_SYSTEM_ACCOUNT = "Populous";
    bytes32 constant CROWDSALE_ACCOUNT = "Crowdsale";

    // This has to be the same one as in Crowdsale
    enum States { Pending, Open, Closed, WaitingForInvoicePayment, PaymentReceived, Completed }

    // The 'ledger' will hold records of the amount of tokens
    // an account holds and what currency it is.
    // This amount will be retrieved using the currency symbol and 
    // account ID as keys.
    // currencySymbol => (accountId => amount)
    mapping(bytes32 => mapping(bytes32 => uint)) ledger;

    mapping(bytes32 => address) currencies;
    mapping(address => bytes32) currenciesSymbols;


    // NON-CONSTANT METHODS

    // Constructor method called when contract instance is 
    // deployed with 'withAccessManager' modifier.
    function Populous(address _accessManager) public withAccessManager(_accessManager) { }
    /**
    BANK MODULE
    */

    // NON-CONSTANT METHODS

    
    /** @dev Creates a new token/currency.
      * @param _tokenName  The name of the currency.
      * @param _decimalUnits The number of decimals the currency has.
      * @param _tokenSymbol The cyrrency symbol, e.g., GBP
      */
    function createCurrency(bytes32 _tokenName, uint8 _decimalUnits, bytes32 _tokenSymbol)
        public
        onlyServer
    {
        // Check if currency already exists
        require(currencies[_tokenSymbol] == 0x0);

        currencies[_tokenSymbol] = new CurrencyToken(address(AM), _tokenName, _decimalUnits, _tokenSymbol);
        
        assert(currencies[_tokenSymbol] != 0x0);

        currenciesSymbols[currencies[_tokenSymbol]] = _tokenSymbol;

        EventNewCurrency(_tokenName, _decimalUnits, _tokenSymbol, currencies[_tokenSymbol]);
    }

    /** @dev Allows a token owner to withdraw from their wallet to another address
      * @param clientExternal The address to transfer withdrawn amount to.
      * @param clientId The client ID.
      * @param currency The cyrrency symbol, e.g., GBP
      * @param amount The amount.
      * @param fee The fee to charge the client.
      */
    function withdraw(address clientExternal, bytes32 clientId, bytes32 currency, uint amount, uint fee) public onlyServer {
    require(currencies[currency] != 0x0 && ledger[currency][clientId] >= amount);

        ledger[currency][clientId] = SafeMath.safeSub(ledger[currency][clientId], amount);
        
        uint mintAmount  = SafeMath.safeSub(amount, fee);

        CurrencyToken(currencies[currency]).mintTokens(mintAmount);
        require(CurrencyToken(currencies[currency]).transfer(clientExternal, mintAmount) == true);

        //deposit fee to Ledger account.
        ledger[currency][LEDGER_SYSTEM_ACCOUNT] = SafeMath.safeAdd(ledger[currency][LEDGER_SYSTEM_ACCOUNT], fee);

        EventWithdrawal(clientExternal, clientId, currency, amount, fee);
    }
    
    /** @dev Mints/Generates a specified amount of tokens 
      * @dev The method calls '_mintTokens' and 
      * @dev uses a modifier from withAccessManager contract to only permit populous to use it.
      * @param amount The amount of tokens to create.
      * @param currency The related currency to mint.
      */
    function mintTokens(bytes32 currency, uint amount)
        public
        onlyServerOrOnlyDCM
        returns (bool success)
    {
        return _mintTokens(currency, amount);
    }

    /** @dev Mints/Generates a specified amount of tokens 
      * @dev The method is called by 'mintTokens'.
      * @dev The method uses SafeMath to carry out safe additions.
      * @param amount The amount of tokens to create.
      * @param currency The related currency to mint.
      */
    function _mintTokens(bytes32 currency, uint amount)
        private returns (bool success)
    {
        if (currencies[currency] != 0x0) {
            ledger[currency][LEDGER_SYSTEM_ACCOUNT] = SafeMath.safeAdd(ledger[currency][LEDGER_SYSTEM_ACCOUNT], amount);
            EventMintTokens(currency, amount);
            return true;
        } else {
            return false;
        }
    }

    /** @dev Destroys a specified amount of tokens 
      * @dev The method uses a modifier from withAccessManager contract to only permit token guardian to use it.
      * @param amount The amount of tokens to create.
      * @param currency The related currency to mint.
      */
    function destroyTokens(bytes32 currency, uint amount)
        public onlyServerOrOnlyDCM returns (bool success)
    {
        return _destroyTokens(currency, amount);
    }
    
    /** @dev Destroys a specified amount of tokens 
      * @dev The method uses a modifier from withAccessManager contract to only permit token guardian to use it.
      * @dev The method uses SafeMath to carry out safe token deductions/subtraction.
      * @param amount The amount of tokens to create.
      * @param currency The related currency to mint.
      */
    function _destroyTokens(bytes32 currency, uint amount)
        private returns (bool success)
    {
        if (currencies[currency] != 0x0) {
            ledger[currency][LEDGER_SYSTEM_ACCOUNT] = SafeMath.safeSub(ledger[currency][LEDGER_SYSTEM_ACCOUNT], amount);
            EventDestroyTokens(currency, amount);
            return true;
        } else {
            return false;
        }
    }    

    // Calls the _transfer method to make a transfer on the internal ledger.
    function transfer(bytes32 currency, bytes32 from, bytes32 to, uint amount) public onlyServerOrOnlyDCM 
        returns (bool success)
    {
        return _transfer(currency, from, to, amount);
    }

    /** @dev Transfers an amount of a specific currency from 'from' to 'to' on the ledger.
      * @param currency The currency for the transaction.
      * @param from The client to debit.
      * @param to The client to credit
      * @param amount The amount to transfer.
      */
    function _transfer(bytes32 currency, bytes32 from, bytes32 to, uint amount) private returns (bool success) {
        if (amount == 0) {return;}
        require(ledger[currency][from] >= amount);
    
        ledger[currency][from] = SafeMath.safeSub(ledger[currency][from], amount);
        ledger[currency][to] = SafeMath.safeAdd(ledger[currency][to], amount);

        EventInternalTransfer(currency, from, to, amount);
        return true;
    }

    
    function importExternalPokens(bytes32 currency, address from, bytes32 accountId) public onlyServer {
        CurrencyToken CT = CurrencyToken(currencies[currency]);
        
        //check balance.
        uint256 balance = CT.balanceOf(from);
        //balance is more than 0, and balance has been destroyed.
        require(CT.balanceOf(from) > 0 && CT.destroyTokensFrom(balance, from) == true);
        //credit ledger
        mintTokens(currency, balance);
        //credit account
        _transfer(currency, LEDGER_SYSTEM_ACCOUNT, accountId, balance);
        //emit event: Imported currency to system
       EventImportedPokens(from, accountId,currency,balance);
    }

    // NON-CONSTANT METHODS

    /** @dev Gets a ledger entry.
      * @param currency The currency for the transaction.
      * @param accountId The entry id.
      * @return uint The currency amount linked to the ledger entry
      */
    function getLedgerEntry(bytes32 currency, bytes32 accountId) public view returns (uint) {
        return ledger[currency][accountId];
    }

    /** @dev Gets the address of a currency.
      * @param currency The currency.
      * @return address The currency address.
      */
    function getCurrency(bytes32 currency) public view returns (address) {
        return currencies[currency];
    }

    /** @dev Gets the currency symbol of a currency.
      * @param currency The currency.
      * @return bytes32 The currency sybmol, e.g., GBP.
      */
    function getCurrencySymbol(address currency) public view returns (bytes32) {
        return currenciesSymbols[currency];
    }

    //get the getLedgerSystemAccount
    function getLedgerSystemAccount() public view returns(bytes32) {
        return LEDGER_SYSTEM_ACCOUNT;
    }

    /**
    END OF BANK MODULE
    */

    /**
    crowdsale MODULE
    */

    // NON-CONSTANT METHODS

    /** @dev Allows a bidder to place a bid in an invoice crowdsale.
      * @param groupIndex The index/location of a group in a set of groups.
      * @param bidderId The bidder id/location in a set of bidders.
      * @param name The bidder name.
      * @param value The bid value.
      * @param crowdsaleAddr The address of the crowdsale contract.
      * @return success A boolean value indicating whether a bid has been successful.
      */
    function bid(address crowdsaleAddr, uint groupIndex, bytes32 bidderId, string name, uint value)
        public onlyServer returns (bool success)
    {
        iCrowdsale CS = iCrowdsale(crowdsaleAddr);
        require(ledger[CS.currencySymbol()][bidderId] >= value && value != 0);//checking bidder poken balance

        uint8 err;
        uint finalValue;
        uint groupGoal;
        bool goalReached;
        (err, finalValue, groupGoal, goalReached) = CS.bid(groupIndex, bidderId, name, value);

        if (err == 0) {
            _transfer(CS.currencySymbol(), bidderId, CROWDSALE_ACCOUNT, finalValue);
            return true;
        } else {
            return false;
        }
    }

    /** @dev Allows a first time bidder to create a new group if they do not belong to a group
      * @dev and place an intial bid.
      * @dev This function creates a group and calls the bid() function.
      * @param groupName The name of the new investor group to be created.
      * @param goal The group funding goal.
      * @param bidderId The bidder id/location in a set of bidders.
      * @param name The bidder name.
      * @param value The bid value.
      * @param crowdsaleAddr The address of the crowdsale contract.
      * @return err 0 or 1 implying absence or presence of error.
      * @return finalValue All bidder's bids value.
      * @return groupGoal An unsigned integer representing the group's goal.
      * @return goalReached A boolean value indicating whether the group goal has reached or not.
      */
    function initialBid(address crowdsaleAddr, string groupName, uint goal, bytes32 bidderId, string name, uint value)
        public onlyServer returns (bool success)
    {
        iCrowdsale CS = iCrowdsale(crowdsaleAddr);
        require(ledger[CS.currencySymbol()][bidderId] >= value && value != 0);//checking bidder poken balance

        uint8 err;
        uint finalValue;
        uint groupGoal;
        bool goalReached;
        (err, finalValue, groupGoal, goalReached) = CS.initialBid(groupName, goal, bidderId, name, value);

        if (err == 0) {
            _transfer(CS.currencySymbol(), bidderId, CROWDSALE_ACCOUNT, finalValue);
            return true;
        } else {
            return false;
        }
    }
    /** @dev Funds an invoice crowdsale address with tokens
      * @param crowdsaleAddr The invoice crowdsale address to fund
      */
    function fundBeneficiary(address crowdsaleAddr) public {
        iCrowdsale CS = iCrowdsale(crowdsaleAddr);
        require(CS.getHasWinnerGroup() == true);// bug fix - there has to be winner group set before beneficiary is funded

        uint8 err;
        uint amount;
        (err, amount) = CS.getAmountForBeneficiary();
        if (err != 0) { return; }

        bytes32 borrowerId = CS.borrowerId();
        bytes32 currency = CS.currencySymbol();
        _transfer(currency, CROWDSALE_ACCOUNT, borrowerId, amount);

        CS.setSentToBeneficiary();
        EventBeneficiaryFunded(crowdsaleAddr, borrowerId, currency, amount);
    }

    /** @dev Transfers refund to loosing groups after crowdsale has closed.
      * @dev This function has to be split, because it might exceed the gas limit, if the groups and bidders are too many.
      * @param crowdsaleAddr The invoice crowdsale address.
      */
/*     function refundLosingGroups(address crowdsaleAddr) public {
        iCrowdsale CS = iCrowdsale(crowdsaleAddr);

        if (States(CS.getStatus()) != States.Closed) { return; }

        bytes32 currency = CS.currencySymbol();
        uint groupsCount = CS.getGroupsCount();
        uint winnerGroupIndex = CS.winnerGroupIndex();

        // Loop all bidding groups
        for (uint groupIndex = 0; groupIndex < groupsCount; groupIndex++) {
            uint biddersCount;
            bool hasReceivedTokensBack;
            ( , , biddersCount, , hasReceivedTokensBack) = CS.getGroup(groupIndex);

            // Check if group is not winner group and has not already been refunded
            if (groupIndex != winnerGroupIndex && hasReceivedTokensBack == false) {
                // Loop all bidders
                for (uint bidderIndex = 0; bidderIndex < biddersCount; bidderIndex++) {
                    bytes32 bidderId;
                    uint bidAmount;
                    bool bidderHasReceivedTokensBack;
                    (bidderId, , bidAmount, bidderHasReceivedTokensBack) = CS.getGroupBidder(groupIndex, bidderIndex);

                    // Check if bidder has already been refunded
                    if (bidderHasReceivedTokensBack == false) {
                        // Refund bidder
                        _transfer(currency, CROWDSALE_ACCOUNT, bidderId, bidAmount);
                        
                        // Save bidder refund in Crowdsale contract
                        CS.setBidderHasReceivedTokensBack(groupIndex, bidderIndex);

                        EventLosingGroupBidderRefunded(crowdsaleAddr, groupIndex, bidderId, currency, bidAmount);
                    }
                }
            }
        }
    } */

    /** @dev Transfers refund to a bidder after crowdsale has closed.
      * @param crowdsaleAddr The invoice crowdsale address.
      * @param groupIndex Group id used to find group among collection of groups.
      * @param bidderIndex Bidder id used to find bidder among collection of bidders in a group.
      */
    function refundLosingGroupBidder(address crowdsaleAddr, uint groupIndex, uint bidderIndex) public {

        iCrowdsale CS = iCrowdsale(crowdsaleAddr);

        if (States(CS.getStatus()) != States.Closed) { return; }

        if (CS.winnerGroupIndex() == groupIndex && CS.getHasWinnerGroup() == true) {return;} //bug fix - check hasWinnerGroup is set in crowdsale

        bytes32 bidderId;
        uint bidAmount;
        bool bidderHasReceivedTokensBack;
        (bidderId, , bidAmount, bidderHasReceivedTokensBack) = CS.getGroupBidder(groupIndex, bidderIndex);

        if (bidderHasReceivedTokensBack == false && bidderId.length != 0) {
            bytes32 currency = CS.currencySymbol();
            _transfer(currency, CROWDSALE_ACCOUNT, bidderId, bidAmount);
            
            // Save bidder refund in Crowdsale contract
            CS.setBidderHasReceivedTokensBack(groupIndex, bidderIndex);

            EventLosingGroupBidderRefunded(crowdsaleAddr, groupIndex, bidderId, currency, bidAmount);
        }
    }

    /** @dev Transfers payment to invoice crowdsale contract waiting for payment.
      * @param crowdsaleAddr The invoice crowdsale address.
      * @param paidAmount The amount to be paid.
      */
    function invoicePaymentReceived(address crowdsaleAddr, uint paidAmount, uint feeAmount) public onlyServer {
        iCrowdsale CS = iCrowdsale(crowdsaleAddr);

        assert(States(CS.getStatus()) == States.WaitingForInvoicePayment || CS.sentToWinnerGroup() == true);   

        require(CS.invoiceAmount() <= paidAmount);
        uint receivedAmount = SafeMath.safeSub(paidAmount, feeAmount);
        bytes32 currency = CS.currencySymbol();
        _mintTokens(currency, paidAmount);

        _transfer(currency, LEDGER_SYSTEM_ACCOUNT, CROWDSALE_ACCOUNT, receivedAmount);
        CS.setPaidAmount(receivedAmount);
        
        EventPaymentReceived(crowdsaleAddr, currency, paidAmount, feeAmount);
    }
    
    /** @dev Transfers funds/payment to bidders in winner group based on contributions/total bid.
      * @param crowdsaleAddr The invoice crowdsale address.
      */
    function fundWinnerGroup(address crowdsaleAddr) public {
        iCrowdsale CS = iCrowdsale(crowdsaleAddr);

        if (States(CS.getStatus()) != States.PaymentReceived) { return; }

        uint winnerGroupIndex = CS.winnerGroupIndex();
        uint biddersCount;
        uint amountRaised;
        bool hasReceivedTokensBack;

        (, , biddersCount, amountRaised, hasReceivedTokensBack) = CS.getGroup(winnerGroupIndex);

        if (hasReceivedTokensBack == true) { return; }

        bytes32 currency = CS.currencySymbol();
        uint paidAmount = CS.paidAmount();

        for (uint bidderIndex = 0; bidderIndex < biddersCount; bidderIndex++) {
            bytes32 bidderId;
            uint bidAmount;
            bool bidderHasReceivedTokensBack;
            (bidderId, , bidAmount, bidderHasReceivedTokensBack) = CS.getGroupBidder(winnerGroupIndex, bidderIndex);

            // Check if bidder has already been funded
            if (bidderHasReceivedTokensBack == true) { continue; }

            // Fund winning bidder based on his contribution
            uint benefitsAmount = bidAmount * paidAmount / amountRaised;

            _transfer(currency, CROWDSALE_ACCOUNT, bidderId, benefitsAmount);
            
            // Save bidder refund in Crowdsale contract
            CS.setBidderHasReceivedTokensBack(winnerGroupIndex, bidderIndex);

            EventWinnerGroupBidderFunded(crowdsaleAddr, winnerGroupIndex, bidderId, currency, bidAmount, benefitsAmount);
        }
    }

    /** @dev Transfers funds/payment to a bidder in winner group.
      * @param crowdsaleAddr The invoice crowdsale address.
      * @param bidderIndex The ID used to find the bidder among collection of bidders in the winner group  with winnerGroupIndex.
      */
    function fundWinnerGroupBidder(address crowdsaleAddr, uint bidderIndex) public {
        iCrowdsale CS = iCrowdsale(crowdsaleAddr);

        if (States(CS.getStatus()) != States.PaymentReceived) { return; }

        uint winnerGroupIndex = CS.winnerGroupIndex();
        
        bytes32 bidderId;
        uint bidAmount;
        bool bidderHasReceivedTokensBack;
        (bidderId, , bidAmount, bidderHasReceivedTokensBack) = CS.getGroupBidder(winnerGroupIndex, bidderIndex);

        if (bidderHasReceivedTokensBack == false && bidderId.length != 0) {
            uint amountRaised;
            (, , , amountRaised, ) = CS.getGroup(winnerGroupIndex);

            bytes32 currency = CS.currencySymbol();
            uint paidAmount = CS.paidAmount();
            // Fund winning bidder based on his contribution
            uint benefitsAmount = bidAmount * paidAmount / amountRaised;

            _transfer(currency, CROWDSALE_ACCOUNT, bidderId, benefitsAmount);
            
            // Save bidder refund in Crowdsale contract
            CS.setBidderHasReceivedTokensBack(winnerGroupIndex, bidderIndex);

            EventWinnerGroupBidderFunded(crowdsaleAddr, winnerGroupIndex, bidderId, currency, bidAmount, benefitsAmount);
        }
    }    

    /**
    END OF CROWDSALE MODULE
    */
    /**
    EXCHANGE MODULE 
     */
     //Note: on the server, fee would have to be deducted from the to_amount. 
    //function exchangeCurrency(bytes32 clientId, bytes32 from_currency, bytes32 to_currency, uint from_amount, uint to_amount, uint256 fee_amount, bytes32 conversion_rate)
    function exchangeCurrency(bytes32 clientId, bytes32 from_currency, bytes32 to_currency, uint from_amount, uint to_amount, uint256 fee_amount, string conversion_rate)
        public
        onlyServer
    {
        //client must own amount to exchange and currency held must already exist
        require(currencies[from_currency] != 0x0 && currencies[to_currency] != 0x0 && ledger[from_currency][clientId] >= from_amount);

        //transfer pokens to platform account from client, this will deduct from client balance
        _transfer(from_currency, clientId, LEDGER_SYSTEM_ACCOUNT, from_amount);
        //destroy transfered tokens
        _destroyTokens(from_currency, from_amount);
        
        //mint receive amount of to_currency and transfer amount (fees has been deducted from the server.)
        _mintTokens(to_currency, SafeMath.safeAdd(to_amount, fee_amount));
        
        //transfer minted amount
        _transfer(to_currency, LEDGER_SYSTEM_ACCOUNT, clientId, to_amount);
        
        //emit exchange event
        EventExchange(clientId, from_currency, to_currency, from_amount, conversion_rate, to_amount, fee_amount);
    }
}