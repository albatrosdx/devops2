@isTest
private class OpportunityTriggerHandlerTest {
    @isTest
    static void testCopyNameToTestItemOnInsert() {
        Opportunity opp = new Opportunity(
            Name = 'Test Opportunity',
            StageName = 'Prospecting',
            CloseDate = Date.today().addDays(30)
        );

        Test.startTest();
        insert opp;
        Test.stopTest();

        Opportunity result = [SELECT Name, Test_Item__c FROM Opportunity WHERE Id = :opp.Id];
        System.assertEquals(result.Name, result.Test_Item__c, 'Test_Item__c should match Name after insert');
    }

    @isTest
    static void testCopyNameToTestItemOnUpdate() {
        Opportunity opp = new Opportunity(
            Name = 'Original Name',
            StageName = 'Prospecting',
            CloseDate = Date.today().addDays(30)
        );
        insert opp;

        Test.startTest();
        opp.Name = 'Updated Name';
        update opp;
        Test.stopTest();

        Opportunity result = [SELECT Name, Test_Item__c FROM Opportunity WHERE Id = :opp.Id];
        System.assertEquals('Updated Name', result.Test_Item__c, 'Test_Item__c should match Name after update');
    }
}