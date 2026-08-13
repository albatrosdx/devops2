trigger OpportunityTrigger on Opportunity (before insert, before update) {
    OpportunityTriggerHandler.copyNameToTestItem(Trigger.new);
}