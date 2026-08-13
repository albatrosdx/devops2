public with sharing class OpportunityTriggerHandler {
    public static void copyNameToTestItem(List<Opportunity> opportunities) {
        for (Opportunity opp : opportunities) {
            opp.Test_Item__c = opp.Name;
        }
    }
}