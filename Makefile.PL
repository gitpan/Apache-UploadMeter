use ExtUtils::MakeMaker;
# See lib/ExtUtils/MakeMaker.pm for details of how to influence
# the contents of the Makefile that is written.
WriteMakefile(
    'NAME'		=> 'Apache::UploadMeter',
    'VERSION_FROM'	=> 'UploadMeter.pm', # finds $VERSION
    'PREREQ_PM'		=> {Apache=>0.01,Apache::Request=>0.33,Apache::SSI=>2.16,Cache::Cache=>0.09,Number::Format=>0.01,Date::Format=>0.01}, # e.g., Module::Name => 1.1
    ($] >= 5.005 ?    ## Add these new keywords supported since 5.005
      (ABSTRACT_FROM => 'UploadMeter.pm', # retrieve abstract from module
       AUTHOR     => 'Issac Goldstand <margol@beamartyr.net>') : ()),
);
