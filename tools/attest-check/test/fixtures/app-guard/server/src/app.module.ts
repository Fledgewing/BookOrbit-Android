import { Module } from '@nestjs/common';
import { APP_GUARD } from '@nestjs/core';
import { AppAttestGuard } from './modules/app-attest/app-attest.guard';
import { GLOBAL_GUARDS } from './common/guards/global-guards';

@Module({
  providers: [
    ...GLOBAL_GUARDS.map((useClass) => ({ provide: APP_GUARD, useClass })),
    { provide: APP_GUARD, useClass: AppAttestGuard },
  ],
})
export class AppModule {}
